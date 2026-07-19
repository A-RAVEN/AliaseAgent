#ifndef SEARXNG_HARNESS_H
#define SEARXNG_HARNESS_H

#include <string>
#include <chrono>
#include <thread>
#include <curl/curl.h>
#include <cstdlib>

// ============================================================================
// SearXNGHarness — manage local SearXNG process for live integration tests
// ============================================================================

class SearXNGHarness {
public:
  /// Check if SearXNG tools directory is set up.
  static bool is_available() {
    // Check if tools/searxng/venv exists
    CURL* curl = curl_easy_init();
    if (!curl) return false;
    curl_easy_setopt(curl, CURLOPT_URL, "http://localhost:8888/search?q=test&format=json");
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 2L);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 2L);
    curl_easy_setopt(curl, CURLOPT_NOBODY, 1L);
    CURLcode res = curl_easy_perform(curl);
    long http = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &http);
    curl_easy_cleanup(curl);
    return res == CURLE_OK && http > 0 && http < 500;
  }

  /// Wait for SearXNG to become ready on localhost:8888.
  /// Returns true if ready within timeout seconds.
  static bool wait_ready(int timeout_sec = 10) {
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(timeout_sec);
    while (std::chrono::steady_clock::now() < deadline) {
      if (is_available()) return true;
      std::this_thread::sleep_for(std::chrono::milliseconds(500));
    }
    return false;
  }
};

#endif
