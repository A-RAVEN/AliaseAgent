#ifndef TEMP_DIR_H
#define TEMP_DIR_H

#include "tools.h"
#include <string>
#include <fstream>
#include <cstdlib>
#include <cstdio>

#ifdef _WIN32
#include <windows.h>
#include <direct.h>
#define mkdir_impl(p) _mkdir(p)
#define rmdir_impl(p)  _rmdir(p)
#define unlink_impl(p) _unlink(p)
#else
#include <sys/stat.h>
#include <dirent.h>
#include <unistd.h>
#define mkdir_impl(p) mkdir(p, 0755)
#define rmdir_impl(p)  rmdir(p)
#define unlink_impl(p) unlink(p)
#endif

// ---------------------------------------------------------------------------
// TempDir — RAII temporary directory
// Creates a unique directory under the system temp path.
// The directory and all its contents are removed on destruction.
// ---------------------------------------------------------------------------

class TempDir {
public:
    TempDir() {
#ifdef _WIN32
        char tmp_path[MAX_PATH];
        GetTempPathA(MAX_PATH, tmp_path);
        char dir_path[MAX_PATH];
        GetTempFileNameA(tmp_path, "st_", 0, dir_path);
        // GetTempFileNameA creates a FILE — delete it and use the name as a dir
        unlink_impl(dir_path);
        mkdir_impl(dir_path);
        path_ = dir_path;
        // Normalize backslashes
        for (auto& c : path_) if (c == '\\') c = '/';
#else
        char tmp[] = "/tmp/sidecar_test_XXXXXX";
        char* p = mkdtemp(tmp);
        if (p) path_ = p;
#endif
    }

    ~TempDir() {
        if (path_.empty()) return;
        remove_all(path_);
    }

    const std::string& path() const { return path_; }

    /// Write content to a file relative to the temp directory.
    /// Creates parent directories as needed.
    void write(const std::string& rel_path, const std::string& content) {
        std::string full = path_ + "/" + rel_path;

        // Create parent directories
        size_t last_slash = full.rfind('/');
        if (last_slash != std::string::npos) {
            std::string parent = full.substr(0, last_slash);
            mkdirs(parent);
        }

        std::ofstream f(full, std::ios::binary);
        f << content;
        f.close();
    }

    /// Create a subdirectory relative to the temp directory.
    void mkdir(const std::string& rel_path) {
        std::string full = path_ + "/" + rel_path;
        mkdirs(full);
    }

private:
    std::string path_;

    static void mkdirs(const std::string& path) {
        std::string current;
        for (size_t i = 0; i < path.size(); ++i) {
            current += path[i];
            if (path[i] == '/' || i == path.size() - 1) {
                if (!current.empty() && current.back() == '/')
                    current.pop_back();
                if (!current.empty()) {
#ifdef _WIN32
                    // On Windows, skip drive root (e.g., "C:")
                    if (current.size() == 2 && current[1] == ':')
                        continue;
#endif
                    mkdir_impl(current.c_str());
                }
                if (i < path.size()) current += '/';
            }
        }
    }

    static void remove_all(const std::string& dir_path) {
#ifdef _WIN32
        std::string search = dir_path + "/*";
        WIN32_FIND_DATAA fd;
        HANDLE h = FindFirstFileA(search.c_str(), &fd);
        if (h == INVALID_HANDLE_VALUE) {
            rmdir_impl(dir_path.c_str());
            return;
        }
        do {
            if (std::strcmp(fd.cFileName, ".") == 0 || std::strcmp(fd.cFileName, "..") == 0)
                continue;
            std::string full = dir_path + "/" + fd.cFileName;
            if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
                remove_all(full);
            } else {
                unlink_impl(full.c_str());
            }
        } while (FindNextFileA(h, &fd));
        FindClose(h);
        rmdir_impl(dir_path.c_str());
#else
        DIR* d = opendir(dir_path.c_str());
        if (!d) {
            rmdir_impl(dir_path.c_str());
            return;
        }
        struct dirent* entry;
        while ((entry = readdir(d)) != nullptr) {
            if (std::strcmp(entry->d_name, ".") == 0 || std::strcmp(entry->d_name, "..") == 0)
                continue;
            std::string full = dir_path + "/" + entry->d_name;
            struct stat st;
            if (stat(full.c_str(), &st) == 0 && S_ISDIR(st.st_mode)) {
                remove_all(full);
            } else {
                unlink_impl(full.c_str());
            }
        }
        closedir(d);
        rmdir_impl(dir_path.c_str());
#endif
    }
};

// ---------------------------------------------------------------------------
// WorkspaceGuard — RAII set_workspace cleanup
//
// Calls tools::set_workspace(path) on construction and
// tools::set_workspace("") on destruction.
// Guarantees that g_workspace is reset even if Catch2 REQUIRE assertions
// throw (Catch2 catches exceptions between tests).
// ---------------------------------------------------------------------------

class WorkspaceGuard {
public:
    explicit WorkspaceGuard(const std::string& path) {
        tools::set_workspace(path);
    }
    ~WorkspaceGuard() {
        tools::set_workspace("");
    }
};

#endif // TEMP_DIR_H
