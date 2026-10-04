#include "local_error_log.h"
#include <chrono>
#include <fcntl.h>
#include <mutex>
#include <regex>
#include <string>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
namespace {
std::mutex mutex;
std::string directory;
constexpr size_t SEGMENT_BYTES = 8 * 1024 * 1024;
std::string Escape(const std::string& text) {
    std::string out;
    for (unsigned char c : text) {
        if(c=='"'||c=='\\'){out+='\\';out+=c;}
        else if(c=='\n')out+="\\n";
        else if(c=='\r')out+="\\r";
        else if(c=='\t')out+="\\t";
        else if(c>=32)out+=c;
    }
    return out;
}
bool WriteAll(int fd,const std::string& text) {
    size_t offset=0;
    while(offset<text.size()) {
        const ssize_t n=write(fd,text.data()+offset,text.size()-offset);
        if(n<=0)return false;
        offset+=static_cast<size_t>(n);
    }
    return fsync(fd)==0;
}
}
namespace LocalErrorLog {
std::string Redact(const std::string& input) {
    std::string text=input.substr(0,16000);
    text=std::regex_replace(text,std::regex(R"rx(("?(?:password|passwd|pass|secret|token|authorization|privateKey|uuid|cookie|apiKey)"?\s*[:=]\s*)"[^"\n]*")rx",std::regex::icase),"$1\"[redacted]\"");
    text=std::regex_replace(text,std::regex(R"rx(((?:password|passwd|pass|secret|token|authorization|privateKey|uuid|cookie|apiKey)\s*[:=]\s*)[^\s,;\}\]]+)rx",std::regex::icase),"$1[redacted]");
    text=std::regex_replace(text,std::regex(R"rx((?:https?|trojan|vless|vmess|ss|socks5?)://[^\s"<>]+)rx",std::regex::icase),"[url]");
    text=std::regex_replace(text,std::regex(R"rx((?:Bearer|Basic)\s+[A-Za-z0-9._~+/-]+=*)rx",std::regex::icase),"[authorization]");
    text=std::regex_replace(text,std::regex(R"rx(\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?::[0-9]+)?\b)rx"),"[address]");
    text=std::regex_replace(text,std::regex(R"rx([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})rx",std::regex::icase),"[id]");
    text=std::regex_replace(text,std::regex(R"rx((?:[0-9a-f]{0,4}:){3,}[0-9a-f:]{0,39})rx",std::regex::icase),"[address]");
    // Hide arbitrary host suffixes, while retaining source filenames in stacks.
    const std::regex host(R"rx(\b(?:[a-z0-9_-]+\.)+[a-z][a-z0-9_-]*(?::[0-9]+)?\b)rx",std::regex::icase);
    std::string hosts;size_t offset=0;
    for(auto it=std::sregex_iterator(text.begin(),text.end(),host);it!=std::sregex_iterator();++it) {
        const std::string match=it->str();const size_t dot=match.rfind('.');const std::string suffix=match.substr(dot+1).substr(0,match.substr(dot+1).find(':'));
        const bool source=suffix=="ets"||suffix=="ts"||suffix=="js"||suffix=="cpp"||suffix=="h"||suffix=="hpp"||suffix=="c"||suffix=="so"||suffix=="json"||suffix=="jsonl";
        hosts+=text.substr(offset,static_cast<size_t>(it->position())-offset);hosts+=source?match:"[host]";
        offset=static_cast<size_t>(it->position()+it->length());
    }
    text=hosts+text.substr(offset);
    text=std::regex_replace(text,std::regex(R"rx(-----BEGIN[^\n]*KEY-----[\s\S]*?(?:-----END[^\n]*KEY-----|$))rx"),"[private-key]");
    return text;
}
void Configure(const std::string& path) noexcept {
    try {
        const int fd=open(path.c_str(),O_RDONLY|O_DIRECTORY|O_CLOEXEC);
        if(fd<0)return;
        close(fd);
        std::lock_guard<std::mutex> lock(mutex);directory=path;
    } catch(...) {}
}
void Append(const std::string& level,const std::string& component,const std::string& message,const std::string& stack) noexcept {
    try {
        std::lock_guard<std::mutex> guard(mutex);
        if(directory.empty())return;
        const auto now=std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count();
        const std::string safeLevel=level=="warn"?"warn":level=="fatal"?"fatal":"error";
        std::string record="\n{\"schema\":1,\"at\":"+std::to_string(now)+",\"pid\":"+std::to_string(getpid())+",\"level\":\""+safeLevel+"\",\"component\":\""+Escape(Redact(component).substr(0,100))+"\",\"message\":\""+Escape(Redact(message).substr(0,4000))+"\",\"stack\":\""+Escape(Redact(stack).substr(0,8000))+"\"}\n";
        const std::string active=directory+"/error-journal.jsonl";
        const std::string lockPath=directory+"/error-journal.lock";
        const int lockfd=open(lockPath.c_str(),O_CREAT|O_RDWR|O_CLOEXEC,0644);
        if(lockfd<0)return;
        struct LockedFile { int fd; ~LockedFile(){flock(fd,LOCK_UN);close(fd);} } locked{lockfd};
        if(flock(lockfd,LOCK_EX)!=0)return;
        struct stat st{};
        if(stat(active.c_str(),&st)==0 && static_cast<size_t>(st.st_size)+record.size()>SEGMENT_BYTES) {
            unlink((directory+"/error-journal.3.jsonl").c_str());
            for(int i=2;i>=0;--i) {
                const std::string from=directory+(i==0?"/error-journal.jsonl":"/error-journal."+std::to_string(i)+".jsonl");
                const std::string to=directory+"/error-journal."+std::to_string(i+1)+".jsonl";
                rename(from.c_str(),to.c_str());
            }
            record="\n{\"schema\":1,\"at\":"+std::to_string(now)+",\"level\":\"warn\",\"component\":\"retention\",\"message\":\"Error segment rotated; oldest segment is evicted when 32 MiB capacity is reached\"}\n"+record;
        }
        const int fd=open(active.c_str(),O_CREAT|O_APPEND|O_WRONLY|O_CLOEXEC,0644);
        if(fd>=0){WriteAll(fd,record);close(fd);}
    } catch(...) {} // Recording never replaces or throws over the original failure.
}
}
