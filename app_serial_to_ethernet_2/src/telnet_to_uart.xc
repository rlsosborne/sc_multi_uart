#include "telnet_to_uart.h"
#include "s2e_conf.h"
#include "s2e_def.h"
#include "xc_ptr.h"
#include "telnet.h"
#include <safestring.h>


static char welcome_msg[] =
"Welcome to serial to ethernet telnet server demo!\nThis server is connected to uart channel 0\n";

static uart_channel_state_t uart_channel_state[NUM_UART_CHANNELS];

#pragma unsafe arrays
int telnet_to_uart_get_port(int id)
{
  return uart_channel_state[id].ip_port;
}

#pragma unsafe arrays
int telnet_to_uart_port_used_elsewhere(int id, int telnet_port)
{
  for (int i=0;i<NUM_UART_CHANNELS;i++) {
    if (i != id &&
        uart_channel_state[i].ip_port == telnet_port)
      return 1;
  }
  return 0;
}

#pragma unsafe arrays
void telnet_to_uart_set_port(chanend c_xtcp, int id, int ip_port)
{
  xtcp_unlisten(c_xtcp, uart_channel_state[id].ip_port);
  uart_channel_state[id].ip_port = ip_port;
  xtcp_listen(c_xtcp, uart_channel_state[id].ip_port, XTCP_PROTOCOL_TCP);
  return;
}

#pragma unsafe arrays
void telnet_to_uart_init(chanend c_xtcp, chanend c_uart_data)
{
  for (int i=0;i<NUM_UART_CHANNELS;i++) {
    uart_channel_state[i].current_rx_buffer = -1;
    uart_channel_state[i].conn_id = -1;
    uart_channel_state[i].ip_port = TELNET_UART_BASE_PORT + i;

    c_uart_data <: array_to_xc_ptr(uart_channel_state[i].uart_tx_buffer);

    c_uart_data <: array_to_xc_ptr(uart_channel_state[i].uart_rx_buffer[0]);
    c_uart_data <: array_to_xc_ptr(uart_channel_state[i].uart_rx_buffer[1]);

    xtcp_listen(c_xtcp, uart_channel_state[i].ip_port, XTCP_PROTOCOL_TCP);
  }
}

#pragma unsafe arrays
static int get_uart_id_from_port(int p) {
  if (p == -1)
    return -1;

  for (int i=0;i<NUM_UART_CHANNELS;i++) {
    if (p == uart_channel_state[i].ip_port)
        return i;
  }
  return -1;
}

#pragma unsafe arrays
static int get_conn_id_from_uart_id(int i) {
  if (i == -1)
    return -1;
  return uart_channel_state[i].conn_id;
}

#pragma unsafe arrays
void telnet_to_uart_event_handler(chanend c_xtcp,
                                  chanend c_uart_data,
                                  xtcp_connection_t &conn)
{
  int uart_id, len, close_request;

  switch (conn.event)
    {
    case XTCP_IFUP:
    case XTCP_IFDOWN:
    case XTCP_ALREADY_HANDLED:
      return;
    default:
      break;
    }

  uart_id = get_uart_id_from_port(conn.local_port);

  if (uart_id != -1) {
    switch (conn.event)
      {
      case XTCP_NEW_CONNECTION:
        uart_channel_state[uart_id].conn_id = conn.id;
        uart_channel_state[uart_id].sending_welcome = 1;
        uart_channel_state[uart_id].sending_data = 0;
        init_telnet_parse_state(uart_channel_state[uart_id].parse_state);
        xtcp_ack_recv_mode(c_xtcp, conn);
        xtcp_init_send(c_xtcp, conn);
        break;
      case XTCP_RECV_DATA:
        len = xtcp_recv(c_xtcp, uart_channel_state[uart_id].uart_tx_buffer);
        #ifdef S2E_DEBUG_WATERMARK_UNUSED_BUFFER_AREA
        for (int i=len;i<UIP_CONF_RECEIVE_WINDOW;i++)
          uart_channel_state[uart_id].uart_tx_buffer[i] = 'C';
        #endif
        len = parse_telnet_buffer(uart_channel_state[uart_id].uart_tx_buffer,
                                  len,
                                  uart_channel_state[uart_id].parse_state,
                                  close_request);
        if (close_request)
          xtcp_close(c_xtcp, conn);
        if (len) {
          mutual_comm_initiate(c_uart_data);
          c_uart_data <: NEW_UART_TX_DATA;
          c_uart_data <: uart_id;
          c_uart_data <: len;
        }
        else {
          // no data to send over uart
          xtcp_ack_recv(c_xtcp, conn);
        }
        break;
      case XTCP_REQUEST_DATA:
      case XTCP_SENT_DATA:
        if (uart_channel_state[uart_id].sending_welcome &&
            conn.event != XTCP_SENT_DATA) {
          welcome_msg[sizeof(welcome_msg)-3] = '0'+uart_id;
          xtcp_send(c_xtcp, welcome_msg, sizeof(welcome_msg));
        }
        else {
          uart_channel_state[uart_id].sending_welcome = 0;
          mutual_comm_initiate(c_uart_data);
          c_uart_data <: GET_UART_RX_DATA_TO_SEND;
          c_uart_data <: uart_id;
          c_uart_data :> uart_channel_state[uart_id].current_rx_buffer;
          c_uart_data :> uart_channel_state[uart_id].current_rx_buffer_length;
          if (uart_channel_state[uart_id].current_rx_buffer == -1) {
            xtcp_complete_send(c_xtcp);
            uart_channel_state[uart_id].sending_data = 0;
          }
          else {
            uart_channel_state[uart_id].sending_data = 1;
            xtcp_send(c_xtcp,
                      uart_channel_state[uart_id].uart_rx_buffer[uart_channel_state[uart_id].current_rx_buffer],
                      uart_channel_state[uart_id].current_rx_buffer_length);
          }
        }
        break;
      case XTCP_RESEND_DATA:
        if (uart_channel_state[uart_id].sending_welcome) {
          xtcp_send(c_xtcp, welcome_msg, sizeof(welcome_msg));
        } else {
          xtcp_send(c_xtcp,
                    uart_channel_state[uart_id].uart_rx_buffer[uart_channel_state[uart_id].current_rx_buffer],
                    uart_channel_state[uart_id].current_rx_buffer_length);
        }
        break;
      case XTCP_CLOSED:
      case XTCP_ABORTED:
      case XTCP_TIMED_OUT:
        uart_channel_state[uart_id].conn_id = -1;
        uart_channel_state[uart_id].current_rx_buffer = -1;
        break;
    }
    conn.event = XTCP_ALREADY_HANDLED;
  }
}


static void handle_notification(chanend c_xtcp,
                                chanend c_uart_data)
{
  int cmd, uart_id=0;
  xtcp_connection_t conn;

  while (1) {
    c_uart_data :> cmd;
    c_uart_data :> uart_id;

    conn.id = get_conn_id_from_uart_id(uart_id);

    if (cmd == -1)
      break;

    switch (cmd)
      {
      case SENT_UART_TX_DATA:
        if (conn.id != -1)
          xtcp_ack_recv(c_xtcp, conn);
        break;
      case UART_RX_DATA_READY:
        if (conn.id != -1) {
          if (!uart_channel_state[uart_id].sending_data)
            xtcp_init_send(c_xtcp, conn);
          // Tell the other side that we are sending the data on
          c_uart_data <: 1;
        }
        else {
          // Tell the other side to clear the incoming data
          c_uart_data <: 0;
        }
        break;
      }
  }
}



select telnet_to_uart_notification_handler(chanend c_xtcp,
                                           chanend c_uart_data)
{
 case mutual_comm_notified(c_uart_data):
   handle_notification(c_xtcp, c_uart_data);
   break;
}


