#include "multi_uart_tx.h"
#include <print.h>

extern s_multi_uart_tx_channel uart_tx_channel[UART_TX_CHAN_COUNT];

#define increment(a, inc)  { a = (a+inc); a *= !(a == UART_TX_BUF_SIZE); }

unsigned crc8_helper( unsigned &checksum, unsigned data, unsigned poly )
{
    return crc8shr(checksum, data, poly);
}

void multi_uart_tx_port_init( s_multi_uart_tx_ports &tx_ports )
{
    if (UART_CLOCK_DIVIDER > 1)
    {
        // TODO configuration for external clock
        configure_clock_ref( tx_ports.cbUart, UART_CLOCK_DIVIDER/2 );	
    }
    
    configure_out_port(	tx_ports.pUart, tx_ports.cbUart, 1); // TODO honour stop bit polarity
    
    start_clock( tx_ports.cbUart );
}

#pragma unsafe arrays
unsigned multi_uart_tx_buffer_get( int chan_id )
{
    unsigned word = 0;
    
    int rd_ptr = uart_tx_channel[chan_id].rd_ptr;
    uart_tx_channel[chan_id].nelements++;
    uart_tx_channel[chan_id].buf_empty = 
        (uart_tx_channel[chan_id].nelements == uart_tx_channel[chan_id].nMax);
        
    for (int i = 0; i < uart_tx_channel[chan_id].inc; i++)
    {
        #pragma xta label "buffer_get"
        word |= (uart_tx_channel[chan_id].buf[rd_ptr]) << (8*i);
        rd_ptr++;
        rd_ptr *= !(rd_ptr == UART_TX_BUF_SIZE);
    }
    uart_tx_channel[chan_id].rd_ptr = rd_ptr;
    
    return word;
}

#pragma unsafe arrays
int multi_uart_tx_buffer_put( int chan_id, char data[] )
{
    /* push data into the buffer */
    if (uart_tx_channel[chan_id].nelements) // buffer has space
    {
        int wr_ptr = uart_tx_channel[chan_id].wr_ptr;
        uart_tx_channel[chan_id].nelements--;
        
        for (int i = 0; i < uart_tx_channel[chan_id].inc; i++)
        {
			#pragma xta label "buffer_put"
            uart_tx_channel[chan_id].buf[wr_ptr] = data[i];
            wr_ptr++;
            wr_ptr *= !(wr_ptr == UART_TX_BUF_SIZE);
        }
        uart_tx_channel[chan_id].wr_ptr = wr_ptr;
        uart_tx_channel[chan_id].buf_empty = 0;
    }
    
    return uart_tx_channel[chan_id].nelements;
}

#pragma unsafe arrays
void run_multi_uart_tx( chanend cUART, s_multi_uart_tx_ports &tx_ports )
{
    int chan_id;
    unsigned uart_word;
    int elements_available;
    unsigned run_tx_loop = 0;
    unsigned port_val = 0xFF; // TODO honour IDLE/STOP polarity
    unsigned short port_ts;
    
    multi_uart_tx_port_init( tx_ports );
    
    /* initialise data structures */
	for (int i = 0; i < UART_TX_CHAN_COUNT; i++)
	{
		uart_tx_channel[i].current_word = 0;
		uart_tx_channel[i].current_word_pos = 0; // disable channel
		uart_tx_channel[i].tick_count = 0;
		uart_tx_channel[i].wr_ptr = 0;
		uart_tx_channel[i].rd_ptr = 0;
		uart_tx_channel[i].nelements = uart_tx_channel[i].nMax;
	}

	cUART <: UART_TX_GO;
        
	/* initialise port */
	tx_ports.pUart <: port_val @ port_ts;
	port_ts += 2;

	while (1)
	{
		/* process the next bit on the ports */
		#pragma xta endpoint "bit_ep"
		tx_ports.pUart @ port_ts <: port_val;
		port_ts += 2;

		/* calculate next port_val */
		for (int i = 0; i < UART_TX_CHAN_COUNT; i++)
		{
			/* active and counter tells us we need to send a bit */
			if (uart_tx_channel[i].tick_count == 0 && uart_tx_channel[i].current_word_pos)
			{
				port_val &= ~(1<<i); // clear bit
				port_val |= (uart_tx_channel[i].current_word & 1) << i;
				uart_tx_channel[i].current_word >>= 1;
				uart_tx_channel[i].current_word_pos -= 1;
				uart_tx_channel[i].tick_count = uart_tx_channel[i].clocks_per_bit;
			}
			/* active and not yet completed bit time */
			else if (uart_tx_channel[i].tick_count > 0 && uart_tx_channel[i].current_word_pos)
			{
				uart_tx_channel[i].tick_count--;
			}
			/* check for new buffer value */
			else if (!uart_tx_channel[i].buf_empty)
			{
				/* initialise values */
				//unsigned uart_word = multi_uart_tx_buffer_get( i );
				int chan_id;

				select
				{
					case cUART :> chan_id:
						if (chan_id == i)
						{
							cUART :> uart_word;
							cUART <: 1;
						} else
							cUART <: 0;
						break;
				}

				uart_tx_channel[i].current_word = uart_word;
				uart_tx_channel[i].current_word_pos = uart_tx_channel[i].uart_word_len;
				uart_tx_channel[i].tick_count = uart_tx_channel[i].clocks_per_bit;
			}
		}

		/* check if a word needs to be received - we can receive 1 word per clock,
		 * so buffer can get full
		 */
		/*
		select
		{
		case cUART :> chan_id:
			if (chan_id == UART_TX_STOP)
				run_tx_loop = 0;
			else
			{
				cUART :> uart_word;
				elements_available = multi_uart_tx_buffer_put( chan_id, (uart_word, char[]) );
				cUART <: elements_available;
			}
			break;
		default:
			break;
		} */
            
    }   
}
