#include <cerrno>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <fstream>
#include <hilog/log.h>
#include <sstream>
#include <string>
#include <unistd.h>
#include <vector>

namespace {

constexpr unsigned int LOG_DOMAIN_ID = 0x0002;
constexpr const char* LOG_TAG_NAME = "XrayRun";

using CGoInvokeFunc = char* (*)(char*);
using CGoFreeFunc = void (*)(char*);

volatile sig_atomic_t g_stop = 0;

void OnStop(int /*sig*/)
{
    g_stop = 1;
}

void LogInfo(const std::string& message)
{
    OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN_ID, LOG_TAG_NAME, "%{public}s", message.c_str());
}

void LogError(const std::string& message)
{
    OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN_ID, LOG_TAG_NAME, "%{public}s", message.c_str());
}

std::string DirName(const std::string& path)
{
    size_t slash = path.find_last_of('/');
    if (slash == std::string::npos || slash == 0) {
        return ".";
    }
    return path.substr(0, slash);
}

std::string JsonEscape(const std::string& input)
{
    std::ostringstream output;
    for (char ch : input) {
        switch (ch) {
            case '\\':
                output << "\\\\";
                break;
            case '"':
                output << "\\\"";
                break;
            case '\n':
                output << "\\n";
                break;
            case '\r':
                output << "\\r";
                break;
            case '\t':
                output << "\\t";
                break;
            default:
                output << ch;
                break;
        }
    }
    return output.str();
}

std::string ReadFile(const std::string& path)
{
    std::ifstream in(path.c_str(), std::ios::binary);
    if (!in) {
        return "";
    }
    std::ostringstream buf;
    buf << in.rdbuf();
    return buf.str();
}

bool InvokeSuccess(const std::string& response, std::string& err)
{
    if (response.find("\"success\":true") != std::string::npos) {
        return true;
    }
    err = response.size() > 300 ? response.substr(0, 300) : response;
    return false;
}

} // namespace

int main(int argc, char** argv)
{
    signal(SIGTERM, OnStop);
    signal(SIGINT, OnStop);
    signal(SIGHUP, SIG_IGN);

    if (argc < 3) {
        LogError("usage: libxrayrun.so <config.json> <workdir>");
        return 2;
    }

    const std::string configPath = argv[1];
    const std::string workDir = argv[2];
    const std::string config = ReadFile(configPath);
    if (config.size() < 20) {
        LogError("config file empty or missing");
        return 3;
    }

    setenv("XRAY_LOCATION_ASSET", workDir.c_str(), 1);

    std::string self = argc > 0 && argv[0] != nullptr ? argv[0] : "";
    std::string dir = DirName(self);
    if (!dir.empty() && dir != ".") {
        if (chdir(dir.c_str()) != 0) {
            LogError(std::string("chdir failed: ") + std::strerror(errno));
        }
    }

    LogInfo(std::string("fresh process dlopen libxray.so cwd=") + dir);
    void* handle = dlopen("./libxray.so", RTLD_NOW | RTLD_LOCAL);
    if (handle == nullptr) {
        handle = dlopen("libxray.so", RTLD_NOW | RTLD_LOCAL);
    }
    if (handle == nullptr) {
        const char* error = dlerror();
        LogError(std::string("dlopen libxray.so failed: ") + (error != nullptr ? error : "unknown"));
        return 4;
    }

    auto invoke = reinterpret_cast<CGoInvokeFunc>(dlsym(handle, "CGoInvoke"));
    auto freefn = reinterpret_cast<CGoFreeFunc>(dlsym(handle, "CGoFree"));
    if (invoke == nullptr || freefn == nullptr) {
        LogError("CGoInvoke/CGoFree missing");
        return 5;
    }

    std::string request = std::string("{\"apiVersion\":1,\"method\":\"runXrayFromJson\",\"payload\":{\"configJSON\":\"") +
        JsonEscape(config) + "\"}}";
    std::vector<char> buffer(request.begin(), request.end());
    buffer.push_back('\0');
    LogInfo("fresh process CGoInvoke runXrayFromJson");
    char* raw = invoke(buffer.data());
    if (raw == nullptr) {
        LogError("CGoInvoke returned null");
        return 6;
    }
    std::string response(raw);
    freefn(raw);
    std::string err;
    if (!InvokeSuccess(response, err)) {
        LogError(std::string("runXrayFromJson failed: ") + err);
        return 7;
    }
    LogInfo("xray started in isolated process, waiting");

    while (g_stop == 0) {
        pause();
    }

    LogInfo("stopping xray");
    std::string stopReq = "{\"apiVersion\":1,\"method\":\"stopXray\",\"payload\":{}}";
    std::vector<char> stopBuf(stopReq.begin(), stopReq.end());
    stopBuf.push_back('\0');
    char* stopRaw = invoke(stopBuf.data());
    if (stopRaw != nullptr) {
        freefn(stopRaw);
    }
    return 0;
}
