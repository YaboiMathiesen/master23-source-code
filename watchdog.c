#include <stdio.h>
#include <stdlib.h>
#include "spi.h"
#include "helpers.h"

#define LOOPBACK 0 //if we want loopback

typedef struct {
	volatile uint32_t data; //0x00 gpio input
	volatile uint32_t output;//0x04 gpio output
	volatile uint32_t dir; //0x08 direction
} gpio_regs_t;


int main(void){
	//Initialize golden memory(Must match values on FPGA)
	uint8_t golden[16];
	uint8_t coefficient = 2;
	for(uint8_t i = 0; i < 16; i++){
		golden[i] = coefficient;
		coefficient += 2;
	}

	//SPICTRL0 base address
	spi_regs_t* spi_regs = (spi_regs_t*) 0x80309000;

	//GPIO0 base address
	gpio_regs_t* gpio_regs = (gpio_regs_t*) 0x8030c000;
	//Remember to double check that pin is configured for GPIO usage
	gpio_regs->dir |= 0x00000082; //Should set GPIO7 and GPIO1 to output mode
	gpio_regs->output |= 0x00000082; //Sets basically ss_n and reset_n high

	//Config registers for pin maps, see GR716A user manual
	volatile uint32_t* gpio0_cfg_reg = (volatile uint32_t*) 0x8000d000;
	volatile uint32_t* gpio1_cfg_reg = (volatile uint32_t*) 0x8000d004;
	volatile uint32_t* lvds_cfg_reg = (volatile uint32_t*) 0x8000d030;	
	export_pins(gpio0_cfg_reg,gpio1_cfg_reg,lvds_cfg_reg);

	//Setup(Enables core as well)
	spi_setup(spi_regs,LOOPBACK);

	//Error counts					Status bits:
	uint32_t WatchdogRXFSMErrorCount = 0;		//0b0000 0001
	uint32_t WatchdogTXFSMErrorCount = 0;		//0b0000 0010
	uint32_t SPIFSMErrorCount = 0;			//0b0000 0100
	uint32_t FilterFSMErrorCount = 0;		//0b0000 1000	
	uint32_t CoeffmemFSMErrorCount = 0;		//0b0001 0000
	uint32_t CoeffMismatchErrorCount = 0;		//0b0010 0000
	uint32_t FilterDelayLineMismatchErrorCount = 0; //0b0100 0000
	uint32_t FilterCoeffMismatchErrorCount = 0;	//0b1000 0000
	uint32_t rx_received = 0;
	uint32_t message_mismatches = 0;

	//Spi message generation
	uint8_t spi_tx_cmd = 0b00000100; //0x04 is read command
	uint8_t spi_tx_addr = 0x00; //Address of coefficient
	uint8_t spi_tx_data = 0x00; //Golden memory to cross-check
	uint8_t spi_tx_status = 0x00; //Unused by master

	uint32_t previous_tx_message = 0x00000000; // the last message sent
	uint32_t prev_rel_tx_message = 0x00000000; // the one we will receive back
	uint32_t counter = 0x00000000;
	uint8_t received_prev = 1;
	uint8_t resend = 0; // If a message mismatch occurs, resend prev message

	//Received status reg
	uint8_t spi_rx_status = 0x00;

	//Register values
	uint32_t spiEventReg = 0;
	uint32_t spiRxReg = 0;
	
	//Mismatched message
	uint8_t mm_msg = 0;

	//Consecutive errors
	uint8_t consecutiveErrors = 0;
	uint32_t resets = 0;

	uint32_t rx_addr = 0;
	uint32_t rx_data = 0;
	
	//how long to run the program
	uint32_t iterator = 0;
	while(rx_received < 6){
		//Fetch events
		spiEventReg = spi_regs->evt;
		
		//Reboot SPI core if MME asserted
		if(spiEventReg & IRQ_MME_BIT){
			spi_regs->evt |= IRQ_MME_BIT;
			spi_regs->mod |= MODE_ENA_BIT;
			printf("MME asserted, restarting SPI core..\n");
		}
		if(spiEventReg & IRQ_NE_BIT){ //Message received
			spiRxReg = spi_read(spi_regs);

			// Update received message count
			rx_received++;

			// Toggle that we have received a message
			received_prev = 1;

			//Fetches the status field
			spi_rx_status = (uint8_t)(MSG_STS_MSK & spiRxReg);

			rx_addr = (uint32_t)((spiRxReg & MSG_ADR_MSK) >> 16);

			rx_data = (uint32_t)((spiRxReg & MSG_DAT_MSK) >> 8);

			//Check messge contents
			if((((MSG_CMD_MSK & spiRxReg) == 0x04000000) && rx_addr <= 16 && rx_data <= 22) || spiRxReg == 0x00000000){
				
				//Reset consecutive errors
				consecutiveErrors = 0;

				//Fetch error status bits from FPGA (Unused as we focus on SEFIs)
				if(spi_rx_status & STATUS_WG_RXFSM){
					WatchdogRXFSMErrorCount++;	
				}
				if(spi_rx_status & STATUS_WG_TXFSM){
					WatchdogTXFSMErrorCount++;	
				}
				if(spi_rx_status & STATUS_SPI_FSM){
					SPIFSMErrorCount++;
				}
				if(spi_rx_status & STATUS_FL_FSM){
					FilterFSMErrorCount++;	
				}
				if(spi_rx_status & STATUS_CM_FSM){
					CoeffmemFSMErrorCount++;	
				}
				if(spi_rx_status & STATUS_CM_MM){
					CoeffMismatchErrorCount++;	
				}
				if(spi_rx_status & STATUS_FL_MM){
					FilterDelayLineMismatchErrorCount++;	
				}
				if(spi_rx_status & STATUS_FL_MM){
					FilterCoeffMismatchErrorCount++;	
				}
			}else{
				//Mismatch
				//Update consecutive errors
				mm_msg = rx_received;
				consecutiveErrors++;
				//Update mismatches
				message_mismatches++;
				
				//Resend message data
				resend = 1;

				//Reset FPGA if consecutive errors
				if(consecutiveErrors >= 1){

					//Reset FPGA
					gpio_regs->output &= 0xfffffffd;

					//New previous message = 0

					previous_tx_message = 0x00000000; //First message we receive will be 0x00000000;
					//Document resets
					resets++;
	
					//slight delay to let it reset
					for(uint8_t r = 0; r < 10; r++){}
					
					//Unreset FPGA
					gpio_regs->output |= 0x00000002;
				}
			}

		}else{
			if(received_prev){ //Wait for us to receive a message fully before sending new
				received_prev = 0;
				
				

				//Delay sending the next message by enough clock cycles
				for(int i = 0; i < 10; i++){} //Should delay core by substantial amount

				//Message has been received, send next
				if(resend){
					//Dont change data;
					resend = 0;
				}else{
					//Update data				
					//Command stays the same
					//Increment address
					spi_tx_addr++;
					if(spi_tx_addr > 15){
						spi_tx_addr = 0;

					}
					//Fetch next data using address
					spi_tx_data = golden[spi_tx_addr];
				}


				//Set basically SS_N low
				gpio_regs->output &= 0xffffff7f; //0 at pin 7;
				for(int k = 0; k<2;k++){}

				//Sending message
				prev_rel_tx_message = previous_tx_message;
				spi_regs->txm = ((uint32_t)spi_tx_cmd << 24) | ((uint32_t)spi_tx_addr << 16) | ((uint32_t)spi_tx_data << 8) | (uint32_t)spi_tx_status;

				previous_tx_message = ((uint32_t)spi_tx_cmd << 24) | ((uint32_t)spi_tx_addr << 16) | ((uint32_t)spi_tx_data << 8) | (uint32_t)spi_tx_status;

				for(int i = 0; i < 10;i++){};

				//Setting ss_n high
				gpio_regs->output |= 0x00000080;
				//Short delay to await finished transfer
				for(int j = 0; j < 25; j++){}
			}
		}
		
		
	}

	gpio_regs->output &= 0xfffffffd;
	for(uint8_t r = 0; r < 100; r++){}
					
	//Unreset FPGA
	gpio_regs->output |= 0x00000002;

	gpio_regs->output |= 0x00000080;
	
	//Diagnostics
	//printf("Messages received: %u\n",rx_received);
	//printf("Mismatches: %u\n",message_mismatches);
	//printf("Errors detected:\nWatchdog RX_FSM: %u\nWatchdog TX_FSM: %u\nSPI FSM: %u\nFilter FSM: %u\nCoeffmem FSM: %u\nCoeffmem Mismatch: %u\nFilter Delayline Mismatch: %u\nFilter Coeff Mismatch: %u\n",WatchdogRXFSMErrorCount,WatchdogTXFSMErrorCount,SPIFSMErrorCount,FilterFSMErrorCount,CoeffmemFSMErrorCount,CoeffMismatchErrorCount,FilterDelayLineMismatchErrorCount,FilterCoeffMismatchErrorCount);
	//printf("Resets : %u\n",resets);
	//if(mm_msg > 0){
	//	printf("Mismatch at RX = %u\n",mm_msg);
	//}
	return 0;

}