#include <stdio.h>
#include <stdlib.h>

#define MODE_LBCK_BIT		0x40000000
#define MODE_CPOL_BIT		0x20000000
#define MODE_CPHA_BIT		0x10000000
#define MODE_DIV16_BIT		0x08000000
#define MODE_REV_BIT		0x04000000
#define MODE_MS_BIT		0x02000000
#define MODE_ENA_BIT		0x01000000
#define MODE_LEN_BITS		0x00F00000
#define MODE_PM_BITS		0x000F0000
#define MODE_TW_BIT		0x00008000
#define MODE_ASEL_BIT		0x00004000
#define MODE_FACT_BIT		0x00002000
#define MODE_OD_BIT		0x00001000
#define MODE_CG_BITS		0x00000F80
#define MODE_ASELDEL_BITS	0x00000060
#define MODE_TAC_BIT		0x00000010
#define MODE_TTO_BIT		0x00000008
#define MODE_IGSEL_BIT		0x00000004
#define MODE_CITE_BIT		0x00000002

//Shared by event and mask register
#define IRQ_LT_BIT		0x00004000
#define IRQ_OV_BIT		0x00001000
#define IRQ_MME_BIT		0x00000400
#define IRQ_NE_BIT		0x00000200
#define IRQ_NF_BIT		0x00000100

#define MSG_CMD_MSK		0xFF000000
#define MSG_ADR_MSK		0x00FF0000
#define MSG_DAT_MSK		0x0000FF00
#define MSG_STS_MSK		0x000000FF

#define STATUS_WG_RXFSM		0b00000001
#define STATUS_WG_TXFSM		0b00000010
#define STATUS_SPI_FSM		0b00000100
#define STATUS_FL_FSM		0b00001000
#define	STATUS_CM_FSM		0b00010000
#define STATUS_CM_MM		0b00100000
#define STATUS_FL_MM		0b01000000
#define STATUS_FL_CMM		0b10000000

typedef struct {
	volatile uint32_t cap;	//0x00 - Capability
	volatile uint32_t rs0;	//0x04 - Reserved
	volatile uint32_t rs1;	//0x08 - Reserved
	volatile uint32_t rs2;	//0x0C - Reserved
	volatile uint32_t rs3;	//0x10 - Reserved
	volatile uint32_t rs4;	//0x14 - Reserved
	volatile uint32_t rs5;	//0x18 - Reserved
	volatile uint32_t rs6;	//0x1C - Reserved
	volatile uint32_t mod;	//0x20 - Mode
	volatile uint32_t evt;	//0x24 - Event
	volatile uint32_t msk;	//0x28 - Mask
	volatile uint32_t cmd;	//0x2C - Command
	volatile uint32_t txm;	//0x30 - Transmit
	volatile uint32_t rxm;	//0x34 - Receive
	volatile uint32_t sst;	//0x38 - Slave Select
	volatile uint32_t ast;  //0x3C - Automatic Slave Select
} spi_regs_t;

//Functions
void spi_setup(spi_regs_t* spi_regs,uint8_t loopback);
uint32_t spi_read(spi_regs_t* spi_regs);
