/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Interface between the Airoha EN7572 BoB optical frontend driver
 * (airoha-en7572.c) and the xPON MAC driver (airoha-xpon.c).
 */

#ifndef _AIROHA_EN7572_H_
#define _AIROHA_EN7572_H_

#include <linux/types.h>

/**
 * en7572_get_los() - hardware LOS status of the optical frontend
 *
 * Return: 0 = signal present, 1 = loss of signal, negative errno if the
 * frontend is not available or the read failed.
 */
int en7572_get_los(void);

/**
 * en7572_burst_gate() - arm/disarm burst transmission
 * @arm: true once the upstream path is ready (release soft TX_DISABLE
 * and the board TX_DISABLE GPIO), false to force the laser off again
 *
 * Return: 0 on success, negative errno otherwise.
 */
int en7572_burst_gate(bool arm);

/**
 * en7572_set_tx_mode() - select TX eye / line mode
 * @mode: 0 = XGPON (BoB A2 page), 1 = 10G-EPON direction (BoB A0 page)
 *
 * Currently a stub: returns 0 for mode 0, -EOPNOTSUPP otherwise.
 */
int en7572_set_tx_mode(int mode);

#endif /* _AIROHA_EN7572_H_ */
