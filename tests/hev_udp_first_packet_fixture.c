#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <lwip/init.h>
#include <lwip/inet_chksum.h>
#include <lwip/ip4.h>
#include <lwip/ip6.h>
#include <lwip/netif.h>
#include <lwip/pbuf.h>
#include <lwip/prot/ip4.h>
#include <lwip/prot/ip6.h>
#include <lwip/prot/udp.h>
#include <lwip/udp.h>

#include <hev-task-system.h>

#include "app-flow-route.h"

/* APP_FLOW_HELPERS */

/* UDP_DROP_HELPERS */

enum TestMode {
    MODE_NEW,
    MODE_OLD_REMOVE,
    MODE_DISABLED,
    MODE_DROP_ON_SECOND_PASS,
};

static ip_addr_t expected_source;
static ip_addr_t expected_destination;
static enum TestMode mode;
static int family;
static int first_calls;
static int second_calls;

static void
assert_tuple (const AppFlowTuple *tuple)
{
    const size_t size = family == 4 ? 4 : 16;
    const void *source = family == 4
                             ? (const void *)&ip_2_ip4 (&expected_source)->addr
                             : (const void *)ip_2_ip6 (&expected_source)->addr;
    const void *destination =
        family == 4
            ? (const void *)&ip_2_ip4 (&expected_destination)->addr
            : (const void *)ip_2_ip6 (&expected_destination)->addr;

    assert (tuple->family == family);
    assert (tuple->protocol == 17);
    assert (tuple->source_port == 32123);
    assert (tuple->destination_port == 443);
    assert (memcmp (tuple->source, source, size) == 0);
    assert (memcmp (tuple->destination, destination, size) == 0);
}

static void
session_recv (void *arg, struct udp_pcb *pcb, struct pbuf *p,
              const ip_addr_t *addr, u16_t port)
{
    (void)arg;
    second_calls++;
    assert (ip_addr_eq (&pcb->remote_ip, &expected_source));
    assert (pcb->remote_port == 32123);
    assert (ip_addr_eq (&pcb->local_ip, &expected_destination));
    assert (pcb->local_port == 443);
    assert (ip_addr_eq (addr, &expected_source));
    assert (port == 32123);
    pbuf_free (p);
}

static void
listener_recv (void *arg, struct udp_pcb *pcb, struct pbuf *p,
               const ip_addr_t *addr, u16_t port)
{
    AppFlowTuple tuple;
    int result;

    (void)arg;
    (void)p;
    first_calls++;
    assert (ip_addr_eq (&pcb->remote_ip, &expected_source));
    assert (pcb->remote_port == 32123);
    assert (IP_IS_ANY_TYPE_VAL (pcb->local_ip));
    assert (pcb->local_port == 0);
    assert (ip_addr_eq (addr, &expected_destination));
    assert (port == 443);

    if (mode == MODE_OLD_REMOVE) {
        result = app_flow_tuple_init (&tuple, 17, addr, port,
                                      &pcb->local_ip, pcb->local_port);
        assert (result < 0);
        udp_remove (pcb);
        if (first_calls == 3) {
            puts ("old arguments recreated the PCB three times");
            fflush (stdout);
            _Exit (42);
        }
        return;
    }
    if (mode == MODE_DROP_ON_SECOND_PASS) {
        udp_drop_on_second_pass (pcb);
        return;
    }

    if (mode == MODE_NEW) {
        result = app_flow_tuple_init (
            &tuple, 17, &pcb->remote_ip, pcb->remote_port, addr, port);
        assert (result == 0);
        assert_tuple (&tuple);
    }
    /* MODE_DISABLED models begin=-2: tuple selection is not consumed, but
     * the shared first-packet/session path must remain identical. */
    udp_recv (pcb, session_recv, NULL);
}

static err_t
test_netif_init (struct netif *netif)
{
    netif->name[0] = 't';
    netif->name[1] = '0';
    netif->mtu = 1500;
    return ERR_OK;
}

static struct pbuf *
packet_v4 (void)
{
    const u16_t total = IP_HLEN + UDP_HLEN + 1;
    struct pbuf *p = pbuf_alloc (PBUF_RAW, total, PBUF_RAM);
    struct ip_hdr *ip = p->payload;
    struct udp_hdr *udp = (struct udp_hdr *)((char *)p->payload + IP_HLEN);
    ip4_addr_t source;
    ip4_addr_t destination;

    assert (p && p->len == total);
    memset (p->payload, 0, total);
    IP4_ADDR (&source, 10, 2, 3, 4);
    IP4_ADDR (&destination, 1, 1, 1, 1);
    ip_addr_copy_from_ip4 (expected_source, source);
    ip_addr_copy_from_ip4 (expected_destination, destination);
    IPH_VHL_SET (ip, 4, 5);
    IPH_LEN_SET (ip, lwip_htons (total));
    IPH_TTL_SET (ip, 64);
    IPH_PROTO_SET (ip, IP_PROTO_UDP);
    ip->src.addr = source.addr;
    ip->dest.addr = destination.addr;
    IPH_CHKSUM_SET (ip, inet_chksum (ip, IP_HLEN));
    udp->src = lwip_htons (32123);
    udp->dest = lwip_htons (443);
    udp->len = lwip_htons (UDP_HLEN + 1);
    *((char *)udp + UDP_HLEN) = '4';
    return p;
}

static struct pbuf *
packet_v6 (void)
{
    const u16_t payload = UDP_HLEN + 1;
    const u16_t total = IP6_HLEN + payload;
    struct pbuf *p = pbuf_alloc (PBUF_RAW, total, PBUF_RAM);
    struct ip6_hdr *ip = p->payload;
    struct udp_hdr *udp =
        (struct udp_hdr *)((char *)p->payload + IP6_HLEN);
    ip6_addr_t source;
    ip6_addr_t destination;

    assert (p && p->len == total);
    memset (p->payload, 0, total);
    IP6_ADDR (&source, PP_HTONL (0x20010db8), 0, 0, PP_HTONL (1));
    IP6_ADDR (&destination, PP_HTONL (0x26064700), 0, 0,
              PP_HTONL (0x1111));
    ip_addr_copy_from_ip6 (expected_source, source);
    ip_addr_copy_from_ip6 (expected_destination, destination);
    IP6H_VTCFL_SET (ip, 6, 0, 0);
    IP6H_PLEN_SET (ip, payload);
    IP6H_NEXTH_SET (ip, IP6_NEXTH_UDP);
    IP6H_HOPLIM_SET (ip, 64);
    ip6_addr_copy_to_packed (ip->src, source);
    ip6_addr_copy_to_packed (ip->dest, destination);
    udp->src = lwip_htons (32123);
    udp->dest = lwip_htons (443);
    udp->len = lwip_htons (payload);
    *((char *)udp + UDP_HLEN) = '6';
    return p;
}

int
main (int argc, char **argv)
{
    struct netif netif;
    struct udp_pcb *listener;
    ip4_addr_t ip;
    ip4_addr_t mask;
    ip4_addr_t gateway;
    err_t result;

    assert (argc == 3);
    family = atoi (argv[1]);
    if (strcmp (argv[2], "new") == 0)
        mode = MODE_NEW;
    else if (strcmp (argv[2], "old") == 0)
        mode = MODE_OLD_REMOVE;
    else if (strcmp (argv[2], "drop") == 0)
        mode = MODE_DROP_ON_SECOND_PASS;
    else
        mode = MODE_DISABLED;

    assert (family == 4 || family == 6);
    assert (hev_task_system_init () == 0);
    lwip_init ();
    memset (&netif, 0, sizeof (netif));
    IP4_ADDR (&ip, 127, 0, 0, 1);
    IP4_ADDR (&mask, 255, 0, 0, 0);
    IP4_ADDR (&gateway, 127, 0, 0, 1);
    assert (netif_add (&netif, &ip, &mask, &gateway, NULL,
                       test_netif_init, ip4_input) != NULL);
    netif_set_up (&netif);
    netif_set_flags (&netif, NETIF_FLAG_PRETEND_UDP);

    listener = udp_new_ip_type (IPADDR_TYPE_ANY);
    assert (listener);
    udp_bind_netif (listener, &netif);
    assert (udp_bind (listener, NULL, 0) == ERR_OK);
    udp_recv (listener, listener_recv, NULL);

    if (family == 4)
        result = ip4_input (packet_v4 (), &netif);
    else
        result = ip6_input (packet_v6 (), &netif);
    assert (result == ERR_OK);
    assert (mode != MODE_OLD_REMOVE);
    assert (first_calls == 1);
    if (mode == MODE_DROP_ON_SECOND_PASS) {
        assert (second_calls == 0);
        assert (udp_pcbs == listener);
    } else {
        assert (second_calls == 1);
    }
    puts ("first and second callback contract verified");
    return 0;
}
