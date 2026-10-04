#include "local_error_log.h"
#include <cassert>
#include <fstream>
#include <string>
#include <thread>
#include <unistd.h>
#include <sys/wait.h>
#include <fcntl.h>
int main() {
    char directory[]="/tmp/pangolin-errors-XXXXXX";assert(mkdtemp(directory));
    LocalErrorLog::Configure(directory);
    std::thread a([]{for(int i=0;i<30;++i)LocalErrorLog::Append("error","ui","password=SECRET_A https://private.test/token","at Connect (Tunnel.ets:12:3)");});
    std::thread b([]{for(int i=0;i<30;++i)LocalErrorLog::Append("warn","native","{\"password\":\"SECRET_B\"} Bearer SECRET_C 203.0.113.9:443");});
    a.join();b.join();
    std::ifstream in(std::string(directory)+"/error-journal.jsonl");std::string text((std::istreambuf_iterator<char>(in)),{});
    assert(text.find("SECRET_A")==std::string::npos&&text.find("SECRET_B")==std::string::npos&&text.find("SECRET_C")==std::string::npos);
    assert(text.find("private.test")==std::string::npos&&text.find("203.0.113.9")==std::string::npos);
    assert(text.find("Tunnel.ets:12:3")!=std::string::npos);
    size_t count=0,pos=0;while((pos=text.find("\"schema\":1",pos))!=std::string::npos){count++;pos++;}assert(count==60);
    assert(LocalErrorLog::Redact("uuid=8d57dd50-d060-4f23-b0b1-a21230a1ee60 2001:db8::1 vpn.example.com vpn.example.unknownsuffix").find("8d57dd50")==std::string::npos);
    assert(LocalErrorLog::Redact("vpn.example.unknownsuffix")=="[host]");
    assert(LocalErrorLog::Redact("-----BEGIN PRIVATE KEY-----\nSECRET_KEY\n-----END PRIVATE KEY-----").find("SECRET_KEY")==std::string::npos);
    // Multiple real processes append through the same file lock.
    pid_t child=fork();assert(child>=0);
    if(child==0){for(int i=0;i<20;++i)LocalErrorLog::Append("error","child","persisted");_exit(0);}
    for(int i=0;i<20;++i)LocalErrorLog::Append("error","parent","persisted");
    int status=0;assert(waitpid(child,&status,0)==child&&status==0);
    in.close();in.open(std::string(directory)+"/error-journal.jsonl");text.assign(std::istreambuf_iterator<char>(in),{});
    count=0;pos=0;while((pos=text.find("\"schema\":1",pos))!=std::string::npos){count++;pos++;}assert(count==100);
    // Force capacity rollover without manufacturing eight megabytes of errors.
    int fd=open((std::string(directory)+"/error-journal.jsonl").c_str(),O_WRONLY);assert(fd>=0);
    assert(ftruncate(fd,8*1024*1024)==0);close(fd);
    LocalErrorLog::Append("error","native","after restart");
    assert(access((std::string(directory)+"/error-journal.1.jsonl").c_str(),F_OK)==0);
    std::ifstream active(std::string(directory)+"/error-journal.jsonl");std::string current((std::istreambuf_iterator<char>(active)),{});
    assert(current.find("oldest segment is evicted")!=std::string::npos&&current.find("after restart")!=std::string::npos);
    unlink((std::string(directory)+"/error-journal.1.jsonl").c_str());
    LocalErrorLog::Configure("/missing/pangolin");LocalErrorLog::Append("error","native","failed","");
    unlink((std::string(directory)+"/error-journal.jsonl").c_str());unlink((std::string(directory)+"/error-journal.lock").c_str());rmdir(directory);
}
