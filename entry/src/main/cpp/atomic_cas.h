#pragma once
#include <cerrno>
#include <cstdlib>
#include <cstdio>
#include <chrono>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#include <string>
#include <thread>
#include <map>
#include <mutex>

namespace pangolin {
// 0 committed; 1 conflict; -1 I/O/lock error. No temporary file is a commit record.
inline int CompareReplace(const std::string& dest, const std::string& expected,
    const std::string& value, std::string& error) {
  int lock = open((dest + ".lock").c_str(), O_CREAT|O_RDWR|O_CLOEXEC, 0600);
  if (lock < 0) { error="lock-open"; return -1; }
  auto until=std::chrono::steady_clock::now()+std::chrono::milliseconds(150);
  while (flock(lock, LOCK_EX|LOCK_NB)!=0) {
    if (errno!=EWOULDBLOCK || std::chrono::steady_clock::now()>=until) {
      close(lock); error="lock-busy"; return -1;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
  auto finish=[&](int result) { flock(lock,LOCK_UN); close(lock); return result; };
  std::string current;
  int in=open(dest.c_str(),O_RDONLY|O_CLOEXEC);
  if(in<0 && errno!=ENOENT) {error="read-open";return finish(-1);}
  if(in>=0) {
    char buf[8192]; ssize_t n;
    while((n=read(in,buf,sizeof buf))!=0) {
      if(n<0) {if(errno==EINTR)continue;close(in);error="read";return finish(-1);}
      current.append(buf,static_cast<size_t>(n));
      if(current.size()>16*1024*1024) {close(in);error="too-large";return finish(-1);}
    }
    close(in);
  }
  if(current!=expected) {error="conflict";return finish(1);}
  std::string temp=dest+".cas-XXXXXX";
  int out=mkstemp(temp.data());
  if(out<0){error="temp-open";return finish(-1);}
  fchmod(out,0600);
  size_t at=0;
  while(at<value.size()) {
    ssize_t n=write(out,value.data()+at,value.size()-at);
    if(n<0 && errno==EINTR)continue;
    if(n<=0){close(out);unlink(temp.c_str());error="write";return finish(-1);}
    at+=static_cast<size_t>(n);
  }
  if(fsync(out)!=0){close(out);unlink(temp.c_str());error="fsync";return finish(-1);}
  close(out);
  if(rename(temp.c_str(),dest.c_str())!=0){unlink(temp.c_str());error="rename";return finish(-1);}
  auto slash=dest.find_last_of('/');
  std::string dir=slash==std::string::npos?".":dest.substr(0,slash);
  int dfd=open(dir.c_str(),O_RDONLY|O_DIRECTORY|O_CLOEXEC);
  if(dfd<0){error="directory-open-after-commit";return finish(-1);}
  int sync=fsync(dfd);close(dfd);
  if(sync!=0){error="directory-sync-after-commit";return finish(-1);}
  error="committed";return finish(0);
}
}

namespace pangolin {
class FileLeases {
  std::mutex mu_; std::map<int,int> fds_; int next_=1;
public:
  int acquire(const std::string& path) {
    int fd=open(path.c_str(),O_CREAT|O_RDWR|O_CLOEXEC,0600);
    if(fd<0)return 0;
    if(flock(fd,LOCK_EX|LOCK_NB)!=0){close(fd);return 0;}
    std::lock_guard<std::mutex> lock(mu_);
    if(next_<=0 || next_>=2147483646){close(fd);return 0;}
    int token=next_++;fds_[token]=fd;return token;
  }
  bool release(int token) {
    std::lock_guard<std::mutex> lock(mu_);auto it=fds_.find(token);
    if(it==fds_.end())return false;
    int fd=it->second;fds_.erase(it);flock(fd,LOCK_UN);close(fd);return true;
  }
};
}
