#ifndef MOCK_SERVER_H
#define MOCK_SERVER_H

#include <string>
#include <map>
#include <thread>
#include <mutex>
#include <future>
#include <chrono>
#include <fstream>
#include <sstream>
#include <cstring>
#include <stdexcept>

#ifdef _WIN32
#include <winsock2.h>
#pragma comment(lib, "ws2_32.lib")
#else
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
#include <arpa/inet.h>
#endif

// ---------------------------------------------------------------------------
// MockServer — embedded TCP server for testing ModelGateway end-to-end
//
// Runs on a separate std::thread because curl_easy_perform blocks the test
// thread.  Listens on a random port (bind to 0), replays a fixture file as
// a complete HTTP SSE response, and records the incoming HTTP request for
// later inspection by the test.
// ---------------------------------------------------------------------------

class MockServer {
public:
    MockServer() = default;

    ~MockServer() {
        if (thread_.joinable()) thread_.join();
    }

    // ---- lifecycle ----------------------------------------------------------

    /// Start the server thread.  Binds to a random port, then blocks inside
    /// the thread waiting for a single connection.
    void start(const std::string& fixture_path, int http_status = 200) {
        fixture_path_ = fixture_path;
        http_status_ = http_status;
        thread_ = std::thread(&MockServer::serve, this);
    }

    /// Block until the server is listening (bind+listen complete).
    /// Throws std::runtime_error on timeout.
    void wait_ready(std::chrono::seconds timeout = std::chrono::seconds(2)) {
        auto f = ready_.get_future();
        if (f.wait_for(timeout) != std::future_status::ready) {
            throw std::runtime_error("MockServer failed to become ready within timeout");
        }
        port_ = f.get();  // propagate any exception from the promise
    }

    /// Return the base URL that ModelGateway should target.
    std::string base_url() const {
        return "http://localhost:" + std::to_string(port_);
    }

    /// Block until the server thread exits (after handling one connection).
    void join() {
        if (thread_.joinable()) thread_.join();
    }

    // ---- request inspection ------------------------------------------------

    std::string last_method() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return last_method_;
    }

    std::string last_path() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return last_path_;
    }

    std::string last_header(const std::string& name) const {
        std::lock_guard<std::mutex> lock(mutex_);
        // Case-insensitive lookup
        for (const auto& kv : last_headers_) {
            if (iequals(kv.first, name)) return kv.second;
        }
        return "";
    }

    std::string last_body() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return last_body_;
    }

private:
    // ---- server thread ------------------------------------------------------

    void serve() {
#ifdef _WIN32
        SOCKET sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
#else
        int sock = socket(AF_INET, SOCK_STREAM, 0);
#endif
        if (sock < 0) {
            ready_.set_exception(std::make_exception_ptr(
                std::runtime_error("socket() failed")));
            return;
        }

        int opt = 1;
#ifdef _WIN32
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, (const char*)&opt, sizeof(opt));
#else
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
#endif

        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = inet_addr("127.0.0.1");
        addr.sin_port = 0;  // OS picks a random port

        if (bind(sock, (sockaddr*)&addr, sizeof(addr)) < 0) {
#ifdef _WIN32
            closesocket(sock);
#else
            close(sock);
#endif
            ready_.set_exception(std::make_exception_ptr(
                std::runtime_error("bind() failed")));
            return;
        }

        // Read back the assigned port
#ifdef _WIN32
        int addr_len = sizeof(addr);
#else
        socklen_t addr_len = sizeof(addr);
#endif
        getsockname(sock, (sockaddr*)&addr, &addr_len);
        uint16_t assigned_port = ntohs(addr.sin_port);

        if (listen(sock, 1) < 0) {
#ifdef _WIN32
            closesocket(sock);
#else
            close(sock);
#endif
            ready_.set_exception(std::make_exception_ptr(
                std::runtime_error("listen() failed")));
            return;
        }

        // Signal the test thread — server is ready
        ready_.set_value(assigned_port);

        // Accept exactly one connection (blocks until CURL connects)
#ifdef _WIN32
        SOCKET client = accept(sock, nullptr, nullptr);
#else
        int client = accept(sock, nullptr, nullptr);
#endif
        if (client < 0) {
#ifdef _WIN32
            closesocket(sock);
#else
            close(sock);
#endif
            return;
        }

        // Read the HTTP request
        std::string request = read_http_request(client);

        // Parse and store for test inspection
        parse_request(request);

        // Build and send HTTP response with SSE fixture
        std::string response = build_response();
#ifdef _WIN32
        send(client, response.c_str(), (int)response.size(), 0);
#else
        send(client, response.c_str(), response.size(), 0);
#endif
        // Close client socket immediately to prevent keep-alive reuse
#ifdef _WIN32
        closesocket(client);
        closesocket(sock);
#else
        close(client);
        close(sock);
#endif
    }

    // ---- HTTP helpers -------------------------------------------------------

    std::string read_http_request(
#ifdef _WIN32
        SOCKET client
#else
        int client
#endif
    ) {
        std::string data;
        char buf[4096];
        // Read until we've got the full headers + body
        // Simple approach: keep reading until Content-Length bytes received
        // or socket closes
        while (true) {
#ifdef _WIN32
            int n = recv(client, buf, sizeof(buf), 0);
#else
            ssize_t n = recv(client, buf, sizeof(buf), 0);
#endif
            if (n <= 0) break;
            data.append(buf, n);
            // Stop once we have headers and body (double CRLF + Content-Length)
            size_t hdr_end = data.find("\r\n\r\n");
            if (hdr_end != std::string::npos) {
                // Try to find Content-Length
                std::string headers = data.substr(0, hdr_end);
                size_t cl_pos = headers.find("Content-Length:");
                if (cl_pos == std::string::npos) {
                    cl_pos = headers.find("content-length:");
                }
                if (cl_pos != std::string::npos) {
                    size_t val_start = headers.find(":", cl_pos) + 1;
                    while (val_start < headers.size() &&
                           (headers[val_start] == ' ' || headers[val_start] == '\t'))
                        val_start++;
                    size_t val_end = headers.find("\r\n", cl_pos);
                    std::string cl_str = headers.substr(val_start, val_end - val_start);
                    long content_len = std::stol(cl_str);
                    if ((long)(data.size() - hdr_end - 4) >= content_len) break;
                } else {
                    // No Content-Length — assume headers only (GET) or wait for close
                    if (data.find("POST") == 0 || data.find("PUT") == 0 || data.find("PATCH") == 0) {
                        // POST without Content-Length — read until close
                        continue;
                    }
                    break;
                }
            }
        }
        return data;
    }

    void parse_request(const std::string& raw) {
        std::lock_guard<std::mutex> lock(mutex_);

        // Parse request line: METHOD PATH HTTP/1.1\r\n
        size_t line_end = raw.find("\r\n");
        if (line_end == std::string::npos) return;
        std::string req_line = raw.substr(0, line_end);

        size_t sp1 = req_line.find(' ');
        if (sp1 == std::string::npos) return;
        size_t sp2 = req_line.find(' ', sp1 + 1);
        if (sp2 == std::string::npos) sp2 = req_line.size();

        last_method_ = req_line.substr(0, sp1);
        last_path_ = req_line.substr(sp1 + 1, sp2 - sp1 - 1);

        // Parse headers
        last_headers_.clear();
        size_t pos = line_end + 2;
        while (pos < raw.size()) {
            size_t hdr_end = raw.find("\r\n", pos);
            if (hdr_end == std::string::npos || hdr_end == pos) break;  // empty line = end
            std::string hdr_line = raw.substr(pos, hdr_end - pos);
            size_t colon = hdr_line.find(':');
            if (colon != std::string::npos) {
                std::string key = hdr_line.substr(0, colon);
                std::string val = hdr_line.substr(colon + 1);
                // Trim leading whitespace
                while (!val.empty() && (val[0] == ' ' || val[0] == '\t')) val.erase(0, 1);
                last_headers_[key] = val;
            }
            pos = hdr_end + 2;
        }

        // Parse body (after double CRLF)
        size_t body_start = raw.find("\r\n\r\n");
        if (body_start != std::string::npos) {
            last_body_ = raw.substr(body_start + 4);
        }
    }

    std::string build_response() {
        // Read the fixture file
        std::ifstream f(fixture_path_, std::ios::binary);
        std::ostringstream ss;
        ss << f.rdbuf();
        std::string fixture = ss.str();

        // Build chunked HTTP response
        std::ostringstream resp;
        resp << "HTTP/1.1 " << http_status_ << " ";
        if (http_status_ == 400) resp << "Bad Request";
        else if (http_status_ == 401) resp << "Unauthorized";
        else if (http_status_ == 500) resp << "Internal Server Error";
        else resp << "OK";
        resp << "\r\n";
        resp << "Content-Type: text/event-stream\r\n";
        resp << "Transfer-Encoding: chunked\r\n";
        resp << "\r\n";

        // Chunk the fixture data
        resp << std::hex << fixture.size() << std::dec << "\r\n";
        resp << fixture << "\r\n";
        resp << "0\r\n";   // terminating chunk
        resp << "\r\n";    // end of chunks

        return resp.str();
    }

    // ---- utility ------------------------------------------------------------

    static bool iequals(const std::string& a, const std::string& b) {
        if (a.size() != b.size()) return false;
        for (size_t i = 0; i < a.size(); ++i) {
            if (std::tolower((unsigned char)a[i]) != std::tolower((unsigned char)b[i]))
                return false;
        }
        return true;
    }

    std::thread thread_;
    std::promise<uint16_t> ready_;
    uint16_t port_ = 0;
    std::string fixture_path_;
    int http_status_ = 200;

    mutable std::mutex mutex_;
    std::string last_method_;
    std::string last_path_;
    std::map<std::string, std::string> last_headers_;
    std::string last_body_;
};

#endif // MOCK_SERVER_H
