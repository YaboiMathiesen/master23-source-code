#include <stdio.h>
#include <stdlib.h>
#include "spi.h"

void spi_setup(spi_regs_t* spi_regs,uint8_t loopback){
	//Enable clock for SPI core (If you have not used "grcg enable 7" in grmon)
	//See Clock Gating Unit(Primary) on page 233 in Data sheet

	//Initializes SPI
	if(loopback){
		//Enable with loopback mode(for testing)
		spi_regs->mod = (MODE_LBCK_BIT | MODE_REV_BIT | MODE_MS_BIT | MODE_CG_BITS | MODE_IGSEL_BIT);
		printf("Loopback enabled!\n");
	}else{
		printf("Loopback disabled!\n");
		spi_regs->mod = (MODE_REV_BIT | MODE_MS_BIT | MODE_CG_BITS | MODE_IGSEL_BIT );//| MODE_DIV16_BIT | MODE_PM_BITS); //Dont forget that the core is not enabled yet.
	}

	//Setup interrupts (Might not be necessary if we cant connect it to cpu)
	spi_regs->msk = (IRQ_LT_BIT | IRQ_OV_BIT | IRQ_MME_BIT | IRQ_NE_BIT | IRQ_NF_BIT);

	//Write starting value to TX register
	spi_regs->txm = 0x12345678; //As long as NF is high we can continously write to the register.

	//Slave select (supposedly optional)
	//spi_regs->sst = 0x00000001;

	//Enable SPI core
	spi_regs->mod |= MODE_ENA_BIT;
	printf("SPI enabled with mode: %08x\n",spi_regs->mod);
}

uint32_t spi_read(spi_regs_t* spi_regs){
	//Read and return 
	return spi_regs->rxm;
}