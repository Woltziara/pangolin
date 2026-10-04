#include "atomic_cas.h"
#include <cassert>
#include <fstream>
#include <iostream>
#include <sys/wait.h>
#include <signal.h>
std::string readfile(const std::string& p){std::ifstream f(p);return std::string((std::istreambuf_iterator<char>(f)),{});}
int main(int argc,char**argv){assert(argc==2);std::string p=std::string(argv[1])+"/counter",e;
assert(pangolin::CompareReplace(p,"","0",e)==0);assert(pangolin::CompareReplace(p,"wrong","x",e)==1);assert(readfile(p)=="0");
for(int i=0;i<5;i++){pid_t pid=fork();assert(pid>=0);if(pid==0){for(int k=0;k<30;k++){bool ok=false;for(int j=0;j<1000;j++){auto before=readfile(p);int rc=pangolin::CompareReplace(p,before,std::to_string(std::stoi(before)+1),e);if(rc==0){ok=true;break;}usleep(1000);}if(!ok)_exit(2);}_exit(0);}}
for(int i=0;i<5;i++){int status;assert(wait(&status)>0);assert(WIFEXITED(status)&&WEXITSTATUS(status)==0);}assert(readfile(p)=="150");
pangolin::FileLeases a,b;auto path=std::string(argv[1])+"/maintenance.lock";int token=a.acquire(path);assert(token>0);assert(b.acquire(path)==0);assert(a.release(token));assert(!a.release(token));int t=b.acquire(path);assert(t>0);assert(b.release(t));
int pipefd[2];assert(pipe(pipefd)==0);auto child=fork();assert(child>=0);if(child==0){close(pipefd[0]);pangolin::FileLeases c;int token=c.acquire(path);char ok=token>0?'1':'0';write(pipefd[1],&ok,1);pause();_exit(0);}close(pipefd[1]);char ok;assert(read(pipefd[0],&ok,1)==1&&ok=='1');close(pipefd[0]);assert(a.acquire(path)==0);kill(child,SIGKILL);int status;waitpid(child,&status,0);token=a.acquire(path);assert(token>0);assert(a.release(token));
assert(pangolin::CompareReplace(std::string(argv[1])+"/missing-dir/f","","x",e)==-1);
std::cout<<"PASS production CAS: 150 cross-process increments, stale conflict, maintenance exclusion, death releases lease, I/O error\n";
}
