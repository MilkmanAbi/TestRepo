#include "player.h"
#include "log.h"
#include <cstring>
#include <cerrno>
#include <vector>
#include <string>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/wait.h>

// Platform-specific parent death signal (Linux only)
#if defined(__linux__)
#include <sys/prctl.h>
#endif

namespace ytui {

Player::Player() {
    death_pipe_[0] = -1;
    death_pipe_[1] = -1;
}

Player::~Player() { stop(); }

bool Player::is_available() {
    return system("which mpv > /dev/null 2>&1") == 0;
}

// ─── Public API ───────────────────────────────────────────────────────────────

void Player::play(const std::string& url, const std::string& title, PlayMode mode) {
    stop();
    if (mode == PlayMode::Video)
        play_direct(url, title);
    else
        play_piped(url, title, mode);
}

void Player::stop() {
    kill_mpv();
    playing_ = false;
    paused_  = false;
    current_title_.clear();
}

void Player::close_death_pipe() {
    // No longer used, kept for ABI compat
}

bool Player::toggle_pause() {
    if (!playing_ || mpv_pid_ <= 0) return false;
    if (paused_) {
        kill(-mpv_pid_, SIGCONT);
        paused_ = false;
        Log::write("Resumed pgid -%d", mpv_pid_);
    } else {
        kill(-mpv_pid_, SIGSTOP);
        paused_ = true;
        Log::write("Paused pgid -%d", mpv_pid_);
    }
    return paused_;
}

bool Player::is_playing() const {
    if (!playing_ || mpv_pid_ <= 0) return false;

    int status = 0;
    pid_t r = waitpid(mpv_pid_, &status, WNOHANG);

    if (r == mpv_pid_) {
        const_cast<Player*>(this)->playing_ = false;
        const_cast<Player*>(this)->mpv_pid_ = -1;
        return false;
    }

    if (r < 0) {
        const_cast<Player*>(this)->playing_ = false;
        const_cast<Player*>(this)->mpv_pid_ = -1;
        return false;
    }

    // Probe process group - if ESRCH, all dead
    if (kill(-mpv_pid_, 0) < 0 && errno == ESRCH) {
        waitpid(mpv_pid_, &status, WNOHANG);
        const_cast<Player*>(this)->playing_ = false;
        const_cast<Player*>(this)->mpv_pid_ = -1;
        return false;
    }

    return true;
}

std::string Player::now_playing() const {
    if (is_playing()) return current_title_;
    return "";
}

// ─── Simplified child setup ──────────────────────────────────────────────────
// No watchdogs, no death pipes - just setpgid and redirect I/O away from tty

static void child_setup(bool log_to_file) {
    // New process group so we can kill/pause the whole pipeline
    setpgid(0, 0);

    // Linux: die when parent dies (not available on macOS/BSD)
#if defined(__linux__)
    prctl(PR_SET_PDEATHSIG, SIGKILL);
#endif

    // Redirect stdin/stdout/stderr away from the TUI terminal
    int devnull = open("/dev/null", O_RDWR);
    if (devnull >= 0) {
        dup2(devnull, STDIN_FILENO);
        dup2(devnull, STDOUT_FILENO);
        if (!log_to_file)
            dup2(devnull, STDERR_FILENO);
        close(devnull);
    }

    if (log_to_file) {
        std::string el = Log::get_log_dir() + "/mpv.log";
        int ef = open(el.c_str(), O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (ef >= 0) { dup2(ef, STDERR_FILENO); close(ef); }
    }
}

static std::string vol_flag(int v) {
    char buf[32];
    snprintf(buf, sizeof(buf), "--volume=%d", v);
    return buf;
}

// ─── resolve_stream_urls ──────────────────────────────────────────────────────

struct StreamURLs {
    std::string video_url;
    std::string audio_url;
    bool ok = false;
};

static StreamURLs resolve_stream_urls(const std::string& youtube_url) {
    StreamURLs result;

    std::string cmd =
        "yt-dlp -g --no-warnings --no-playlist "
        "-f 'bestvideo[height<=1080]+bestaudio/best[height<=1080]/best' "
        "'" + youtube_url + "' 2>/dev/null";

    Log::write("resolve: %s", cmd.c_str());

    FILE* p = popen(cmd.c_str(), "r");
    if (!p) {
        Log::write("resolve: popen failed: %s", strerror(errno));
        return result;
    }

    char buf[8192];
    std::string line1, line2;

    if (fgets(buf, sizeof(buf), p)) {
        line1 = buf;
        while (!line1.empty() && (line1.back()=='\n'||line1.back()=='\r'))
            line1.pop_back();
    }
    if (fgets(buf, sizeof(buf), p)) {
        line2 = buf;
        while (!line2.empty() && (line2.back()=='\n'||line2.back()=='\r'))
            line2.pop_back();
    }
    pclose(p);

    if (line1.empty()) {
        Log::write("resolve: no output — private/unavailable/rate-limited?");
        return result;
    }

    if (!line2.empty()) {
        result.video_url = line1;
        result.audio_url = line2;
        Log::write("resolve: video=%.80s...", line1.c_str());
        Log::write("resolve: audio=%.80s...", line2.c_str());
    } else {
        result.video_url = line1;
        Log::write("resolve: combined=%.80s...", line1.c_str());
    }

    result.ok = true;
    return result;
}

// ─── play_piped (audio modes) ─────────────────────────────────────────────────

void Player::play_piped(const std::string& url, const std::string& title, PlayMode mode) {
    std::string vol = vol_flag(opts_.volume);

    std::string ytdlp_cmd =
        "yt-dlp --no-warnings --no-playlist "
        "-f 'bestaudio[ext=m4a]/bestaudio[ext=webm]/bestaudio' "
        "--audio-quality 0 "
        "-o - '" + url + "'";

    std::string mpv_cmd = "mpv --no-video --no-terminal " + vol;

    if (!opts_.no_cache) {
        mpv_cmd += " --audio-buffer=2 --cache=yes --demuxer-max-bytes=50M";
    } else {
        mpv_cmd += " --cache=no";
    }

    mpv_cmd += " --audio-pitch-correction=yes";

    if (opts_.no_hardware_accel) {
        mpv_cmd += " --hwdec=no";
    }

    if (mode == PlayMode::AudioLoop) mpv_cmd += " --loop=inf";
    mpv_cmd += " -";

    std::string cmd = ytdlp_cmd + " | " + mpv_cmd;
    Log::write("Piped play: %s", cmd.c_str());

    pid_t pid = fork();

    if (pid == 0) {
        child_setup(Log::is_logdump());
        execlp("sh", "sh", "-c", cmd.c_str(), nullptr);
        _exit(127);
    } else if (pid > 0) {
        usleep(10000);  // 10ms for setpgid to complete
        mpv_pid_       = pid;
        playing_       = true;
        current_title_ = title;
        Log::write("Piped play pid=%d", pid);
    } else {
        Log::write("fork failed: %s", strerror(errno));
    }
}

// ─── play_direct (video mode) ─────────────────────────────────────────────────

void Player::play_direct(const std::string& url, const std::string& title) {
    std::string vol = vol_flag(opts_.volume);

    StreamURLs streams = resolve_stream_urls(url);

    std::vector<std::string> args = {
        "mpv",
        "--force-window=yes",
        "--no-terminal",
        vol,
        "--geometry=854x480",
        "--autofit-larger=70%",
        "--autofit-smaller=640x360",
        "--title=" + title,
    };

    if (streams.ok) {
        args.push_back("--ytdl=no");
        if (!opts_.no_cache) {
            args.push_back("--cache=yes");
            args.push_back("--demuxer-max-bytes=100M");
        } else {
            args.push_back("--cache=no");
        }
        if (opts_.no_hardware_accel) {
            args.push_back("--hwdec=no");
            args.push_back("--vo=libmpv");
        }
        args.push_back(streams.video_url);
        if (!streams.audio_url.empty())
            args.push_back("--audio-file=" + streams.audio_url);

        Log::write("Direct play (fast): vol=%d", opts_.volume);
    } else {
        Log::write("Direct play (slow fallback --ytdl=yes): %s", url.c_str());
        args.push_back("--ytdl=yes");
        args.push_back("--ytdl-format=bestvideo[height<=1080]+bestaudio/best[height<=1080]/best");
        if (!opts_.no_cache) {
            args.push_back("--cache=yes");
            args.push_back("--demuxer-max-bytes=100M");
        } else {
            args.push_back("--cache=no");
        }
        if (opts_.no_hardware_accel) {
            args.push_back("--hwdec=no");
            args.push_back("--vo=libmpv");
        }
        args.push_back(url);
    }

    std::vector<const char*> argv;
    for (auto& a : args) argv.push_back(a.c_str());
    argv.push_back(nullptr);

    // Simple pipe to detect exec failure (portable, no pipe2)
    int exec_pipe[2];
    if (pipe(exec_pipe) < 0) {
        Log::write("exec pipe failed: %s", strerror(errno));
        return;
    }
    fcntl(exec_pipe[0], F_SETFD, FD_CLOEXEC);
    fcntl(exec_pipe[1], F_SETFD, FD_CLOEXEC);

    pid_t pid = fork();

    if (pid == 0) {
        close(exec_pipe[0]);
        child_setup(Log::is_logdump());
        execvp("mpv", (char* const*)argv.data());
        int err = errno;
        ssize_t w = write(exec_pipe[1], &err, sizeof(err)); (void)w;
        _exit(127);
    } else if (pid > 0) {
        close(exec_pipe[1]);

        int child_errno = 0;
        ssize_t n = read(exec_pipe[0], &child_errno, sizeof(child_errno));
        close(exec_pipe[0]);

        if (n > 0) {
            Log::write("mpv exec failed: %s", strerror(child_errno));
            waitpid(pid, nullptr, 0);
            return;
        }

        usleep(10000);  // 10ms for setpgid
        mpv_pid_       = pid;
        playing_       = true;
        current_title_ = title;
        Log::write("Direct play pid=%d", pid);
    } else {
        close(exec_pipe[0]); close(exec_pipe[1]);
        Log::write("fork failed: %s", strerror(errno));
    }
}

void Player::play_xdg(const std::string& url, const std::string& title) {
    Log::write("xdg/open: %s", url.c_str());

    pid_t pid = fork();

    if (pid == 0) {
        child_setup(false);
#if defined(__APPLE__) && defined(__MACH__)
        execlp("open", "open", url.c_str(), nullptr);
#else
        execlp("xdg-open", "xdg-open", url.c_str(), nullptr);
#endif
        _exit(127);
    } else if (pid > 0) {
        usleep(10000);
        mpv_pid_       = pid;
        playing_       = true;
        current_title_ = title;
    } else {
        Log::write("fork failed: %s", strerror(errno));
    }
}

void Player::kill_mpv() {
    if (mpv_pid_ <= 0) return;
    Log::write("Killing pgid -%d", mpv_pid_);
    kill(-mpv_pid_, SIGTERM);
    int status;
    pid_t r = waitpid(mpv_pid_, &status, WNOHANG);
    if (r == 0) {
        usleep(300000);
        r = waitpid(mpv_pid_, &status, WNOHANG);
        if (r == 0) {
            kill(-mpv_pid_, SIGKILL);
            waitpid(mpv_pid_, &status, 0);
        }
    }
    mpv_pid_ = -1;
}

} // namespace ytui
