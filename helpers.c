#include <stdio.h>
#include <stdlib.h>
#include "helpers.h"
#include <time.h>


void export_pins(volatile uint32_t* gpio0_cfg_reg,volatile uint32_t* gpio1_cfg_reg,volatile uint32_t* lvds_cfg_reg){
	*gpio0_cfg_reg = 0x07770000;
	//*gpio1_cfg_reg = 0x00000007; //Sets SPI_SLV0 (Optional?)
	*lvds_cfg_reg = 0x00000222; //Not sure if this is needed
}