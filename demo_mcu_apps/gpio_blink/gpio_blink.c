/*
 * demo_mcu_apps / gpio_blink  --  drive the 4 wb_gpio pins from the SERV MCU
 *
 * Proves the MCU side of the GPIO: sets all four pins (Tang Nano 9K 48/49/76/30 =
 * gpio[0..3]) to outputs via GPIO_DIR, then walks an incrementing 4-bit pattern on
 * GPIO_DATA. The host can watch the pins change over Modbus (modbus_client.gpio_read
 * / reg 0xEB) -- the same wb_gpio slave both masters share. The current value is
 * also mirrored to the heartbeat (0xE0) as a race-free cross-check (pin read-back
 * should equal it). Parks; reset the MCU (0xE2) to stop. Uses the shared common/ runtime.
 */
#include <stdint.h>
#include "serv_io.h"

void main(void)
{
	GPIO_DIR = 0x0F;                 /* all 4 pins -> outputs */
	unsigned c = 0;
	for (;;) {
		uint8_t v = (uint8_t)(c & 0x0F);
		GPIO_DATA = v;               /* drive the pins */
		HEARTBEAT = v;               /* race-free mirror of what we drove */
		delay(20000);                /* ~5 steps/sec on the bit-serial core */
		c++;
	}
}
