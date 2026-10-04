#ifndef CHUANSHAN_APP_FLOW_ROUTE_H
#define CHUANSHAN_APP_FLOW_ROUTE_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct {
    uint8_t family;
    uint8_t protocol;
    uint16_t source_port;
    uint16_t destination_port;
    uint16_t reserved;
    uint8_t source[16];
    uint8_t destination[16];
} AppFlowTuple;
typedef struct {
    int32_t status;
    uint16_t socks_port;
    uint16_t reserved;
} AppFlowReply;
typedef int (*AppFlowBeginFn)(const AppFlowTuple *, uint64_t *request_id, void *opaque);
typedef void (*AppFlowCancelFn)(uint64_t request_id, void *opaque);
void hev_socks5_tunnel_set_app_route_callbacks(AppFlowBeginFn begin, AppFlowCancelFn cancel, void *opaque);
#ifdef __cplusplus
}
static_assert(sizeof(AppFlowReply) == 8, "App flow reply ABI must be 8 bytes");
#endif
#endif
