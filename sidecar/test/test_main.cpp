#define CATCH_CONFIG_RUNNER
#include <catch2/catch_all.hpp>
#include <curl/curl.h>
#ifdef _WIN32
#include <winsock2.h>
#endif

int main(int argc, char* argv[]) {
#ifdef _WIN32
    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);
#endif
    curl_global_init(CURL_GLOBAL_ALL);

    int result = Catch::Session().run(argc, argv);

    curl_global_cleanup();
#ifdef _WIN32
    WSACleanup();
#endif
    return result;
}
