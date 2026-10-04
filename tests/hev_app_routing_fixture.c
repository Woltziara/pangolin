#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "app-flow-route.h"

typedef int HevTask;
typedef int HevTaskYieldType;
typedef int (*HevTaskIOYielder) (HevTaskYieldType type, void *data);
typedef int HevListNode;
typedef void HevSocks5Session;
typedef struct {
    HevListNode node;
    HevTask *task;
    HevSocks5Session *self;
    AppFlowTuple app_flow;
    uint16_t socks_port;
} HevSocks5SessionData;
typedef struct {
    HevSocks5SessionData data;
    int timeout;
} TestSession;

#define EXPORT_SYMBOL
#define HEV_TASK_WAITIO 2
#define HEV_SOCKS5(value) (value)
#define container_of(ptr, type, member) \
    ((type *)((char *)(ptr)-offsetof (type, member)))

static HevTask task;
static int registered_fd = -1;
static int last_read_fd = -1;

static HevTask *
hev_task_self (void)
{
    return &task;
}

static HevListNode *
hev_socks5_session_get_node (HevSocks5Session *session)
{
    return &((TestSession *)session)->data.node;
}

static int
hev_socks5_get_timeout (void *session)
{
    return ((TestSession *)session)->timeout;
}

static int
hev_task_add_fd (HevTask *self, int fd, unsigned int events)
{
    (void)self;
    assert (events == POLLIN);
    assert (registered_fd == -1);
    registered_fd = fd;
    last_read_fd = fd;
    return 0;
}

static int
hev_task_del_fd (HevTask *self, int fd)
{
    (void)self;
    assert (registered_fd == fd);
    registered_fd = -1;
    return 0;
}

static unsigned int
hev_task_sleep (unsigned int milliseconds)
{
    struct pollfd pfd = { registered_fd, POLLIN, 0 };
    int result = poll (&pfd, 1, (int)milliseconds);

    assert (result >= 0);
    return result ? milliseconds : 0;
}

static void
hev_task_yield (HevTaskYieldType type)
{
    (void)type;
    assert (0 && "route resolver always supplies its yielder");
}

/* HEV_TASK_IO_READ */

/* HEV_ROUTE_CODE */

enum {
    SELECT_A,
    SELECT_B,
    USE_DEFAULT,
    STATUS_REJECT,
    STATUS_UNKNOWN,
    SPLIT_REPLY,
    EOF_REPLY,
    TIMEOUT_REPLY,
    ROUTING_DISABLED,
    BEGIN_REJECT,
};

typedef struct {
    int behavior;
    int write_fd;
    int cancel_count;
    uint64_t request_id;
    pthread_t writer;
    int has_writer;
} CallbackContext;

static void *
writer_entry (void *opaque)
{
    CallbackContext *context = opaque;
    AppFlowReply reply = { 0, 11001, 0 };
    struct timespec delay = { 0, 10 * 1000 * 1000 };

    nanosleep (&delay, NULL);
    if (context->behavior == EOF_REPLY) {
        close (context->write_fd);
        context->write_fd = -1;
        return NULL;
    }
    if (context->behavior == SELECT_B)
        reply.socks_port = 11002;
    else if (context->behavior == USE_DEFAULT)
        reply.status = 1;
    else if (context->behavior == STATUS_REJECT)
        reply.status = -7;
    else if (context->behavior == STATUS_UNKNOWN)
        reply.status = 2;

    if (context->behavior == SPLIT_REPLY) {
        assert (write (context->write_fd, &reply, 3) == 3);
        nanosleep (&delay, NULL);
        assert (write (context->write_fd, (char *)&reply + 3,
                       sizeof (reply) - 3) == (ssize_t)sizeof (reply) - 3);
    } else {
        assert (write (context->write_fd, &reply, sizeof (reply)) ==
                (ssize_t)sizeof (reply));
    }
    return NULL;
}

static int
begin_callback (const AppFlowTuple *tuple, uint64_t *request_id, void *opaque)
{
    CallbackContext *context = opaque;
    int fds[2];
    int flags;

    assert (tuple->family == 4);
    assert (tuple->protocol == 6);
    assert (tuple->source_port == 1234);
    assert (tuple->destination_port == 443);
    if (context->behavior == ROUTING_DISABLED)
        return -2;
    if (context->behavior == BEGIN_REJECT)
        return -1;
    assert (pipe (fds) == 0);
    flags = fcntl (fds[0], F_GETFL);
    assert (flags >= 0 && fcntl (fds[0], F_SETFL, flags | O_NONBLOCK) == 0);
    context->write_fd = fds[1];
    context->request_id++;
    *request_id = context->request_id;
    if (context->behavior != TIMEOUT_REPLY) {
        context->has_writer = 1;
        assert (pthread_create (&context->writer, NULL, writer_entry,
                                context) == 0);
    }
    return fds[0];
}

static void
cancel_callback (uint64_t request_id, void *opaque)
{
    CallbackContext *context = opaque;

    assert (request_id == context->request_id);
    if (context->has_writer) {
        assert (pthread_join (context->writer, NULL) == 0);
        context->has_writer = 0;
    }
    if (context->write_fd >= 0) {
        close (context->write_fd);
        context->write_fd = -1;
    }
    context->cancel_count++;
}

static void
init_session (TestSession *session)
{
    memset (session, 0, sizeof (*session));
    session->timeout = -1;
    session->data.app_flow.family = 4;
    session->data.app_flow.protocol = 6;
    session->data.app_flow.source_port = 1234;
    session->data.app_flow.destination_port = 443;
}

static void
run_reply_case (int behavior, int expected_result, uint16_t expected_port)
{
    CallbackContext context = { behavior, -1, 0, 100, 0, 0 };
    TestSession session;

    init_session (&session);
    hev_socks5_tunnel_set_app_route_callbacks (
        begin_callback, cancel_callback, &context);
    assert (hev_socks5_session_resolve_app_route (&session) ==
            expected_result);
    assert (session.data.socks_port == expected_port);
    assert (context.cancel_count == 1);
    assert (registered_fd == -1);
    assert (fcntl (last_read_fd, F_GETFD) == -1 && errno == EBADF);
}

static void
run_begin_case (int behavior, int expected_result)
{
    CallbackContext context = { behavior, -1, 0, 300, 0, 0 };
    TestSession session;

    init_session (&session);
    hev_socks5_tunnel_set_app_route_callbacks (
        begin_callback, cancel_callback, &context);
    assert (hev_socks5_session_resolve_app_route (&session) ==
            expected_result);
    assert (session.data.socks_port == 0);
    assert (context.cancel_count == 0);
    assert (registered_fd == -1);
}

int
main (void)
{
    TestSession session;
    CallbackContext context = { TIMEOUT_REPLY, -1, 0, 200, 0, 0 };

    run_reply_case (SELECT_A, 0, 11001);
    run_reply_case (SELECT_B, 0, 11002);
    run_reply_case (USE_DEFAULT, 0, 0);
    run_reply_case (SPLIT_REPLY, 0, 11001);
    run_reply_case (STATUS_REJECT, -1, 0);
    run_reply_case (STATUS_UNKNOWN, -1, 0);
    run_reply_case (EOF_REPLY, -1, 0);
    run_reply_case (TIMEOUT_REPLY, -1, 0);
    run_begin_case (ROUTING_DISABLED, 0);
    run_begin_case (BEGIN_REJECT, -1);

    init_session (&session);
    session.timeout = 0;
    hev_socks5_tunnel_set_app_route_callbacks (
        begin_callback, cancel_callback, &context);
    assert (hev_socks5_session_resolve_app_route (&session) == -1);
    assert (context.cancel_count == 1);
    assert (registered_fd == -1);

    init_session (&session);
    session.data.socks_port = 11001;
    assert (hev_socks5_session_get_socks_port (&session, 1080) == 11001);
    session.data.socks_port = 0;
    assert (hev_socks5_session_get_socks_port (&session, 1080) == 1080);

    hev_socks5_tunnel_set_app_route_callbacks (NULL, NULL, NULL);
    assert (hev_socks5_session_resolve_app_route (&session) == 0);
    puts ("hev app routing fixture passed");
    return 0;
}
