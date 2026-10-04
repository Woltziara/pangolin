#pragma once
#define LOG_APP 0
#define LOG_INFO 1
#define LOG_WARN 2
#define LOG_ERROR 3
inline int OH_LOG_Print(int, int, unsigned, const char*, const char*, ...) { return 0; }
