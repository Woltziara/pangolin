#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <lwip/init.h>
#include <lwip/netif.h>
#include <lwip/priv/tcp_priv.h>
#include <lwip/tcp.h>
#include <lwip/udp.h>
#include <hev-task-system.h>

static struct netif *netif;
static struct tcp_pcb *tcp;
static struct udp_pcb *udp;

/* PRODUCTION_GATEWAY_FINI */

int main (int argc, char **argv)
{
    unsigned int round;
    int family, waiting, bound;
    assert (argc == 3);
    family = atoi (argv[1]);
    waiting = strcmp (argv[2], "time-wait") == 0;
    bound = strcmp (argv[2], "bound") == 0;
    assert (family == 4 || family == 6);
    assert (hev_task_system_init () == 0);
    for (round = 0; round < 32; round++) {
        struct tcp_pcb *pending;
        struct pbuf *held = NULL;
        const unsigned char payload[16] = { 0 };
        lwip_init ();
        tcp = tcp_new_ip_type (IPADDR_TYPE_ANY);
        assert (tcp && tcp_bind (tcp, NULL, 0) == ERR_OK);
        tcp = tcp_listen (tcp);
        assert (tcp);
        udp = udp_new_ip_type (IPADDR_TYPE_ANY);
        assert (udp);
        pending = tcp_new_ip_type (family == 4 ? IPADDR_TYPE_V4 : IPADDR_TYPE_V6);
        assert (pending);
        if (bound) {
            pending->local_port = 32123;
            TCP_REG (&tcp_bound_pcbs, pending);
        } else {
            /* Offline fixture: allocated owners only, no input parser,
             * socket, netif, output invocation, or live peer. */
            pending->state = waiting ? TIME_WAIT : SYN_RCVD;
            if (waiting) {
                TCP_REG (&tcp_tw_pcbs, pending);
            } else {
                TCP_REG_ACTIVE (pending);
                assert (tcp_write (pending, payload, sizeof (payload), TCP_WRITE_FLAG_COPY) == ERR_OK);
                assert (pending->unsent && pending->unsent->p);
                held = pending->unsent->p;
                pbuf_ref (held);
                assert (held->ref == 2);
            }
        }
        gateway_fini ();
        if (tcp_active_pcbs || tcp_tw_pcbs || tcp_bound_pcbs || tcp_listen_pcbs.pcbs) {
            fprintf (stderr, "FAIL: TCP owner survives shutdown before pool reinitialization (%s)\n", argv[2]);
            return 42;
        }
        if (held) {
            assert (held->ref == 1);
            pbuf_free (held);
        }
        tcp_slowtmr ();
    }
    hev_task_system_fini ();
    puts ("32 offline TCP allocation/shutdown cycles release all owners");
    return 0;
}
