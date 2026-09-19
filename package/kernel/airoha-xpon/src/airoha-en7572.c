// SPDX-License-Identifier: GPL-2.0-only
/*
 * Clean-room driver for the Airoha EN7572 BoB optical frontend
 * (Gemtek XG2010G, I2C0 @ 0x50/0x51).
 *
 * Protocol facts (register map, init sequence, unit conversions) are
 * taken from docs/EN7572_驱动设计简报.md ("the brief") and
 * docs/EN7581_XPON_寄存器地图.md section 7.  Every point the brief
 * marks as "未确认" has a matching TODO below referencing the unknown
 * item number of brief section 8.
 */

#include <linux/bitfield.h>
#include <linux/debugfs.h>
#include <linux/delay.h>
#include <linux/firmware.h>
#include <linux/gpio/consumer.h>
#include <linux/hwmon.h>
#include <linux/i2c.h>
#include <linux/iopoll.h>
#include <linux/limits.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/nvmem-consumer.h>
#include <linux/of.h>
#include <linux/slab.h>
#include <linux/unaligned.h>

#include "airoha-en7572.h"

#define EN7572_A2_ADDR			0x51	/* mailbox/diagnostic client */
#define EN7572_CHIP_ID			0x1388

/* 2-byte register addresses, A2 space */
#define EN7572_REG_CHIP_ID		0x408	/* reads 0x1388 */
#define EN7572_REG_CHIP_INFO		0x40a	/* reads 0x007d (info only) */

/* SFF-8472 A2 low page (multi-byte values big-endian) */
#define EN7572_A2_AW_THLD		0x00	/* 40 bytes alarm/warning */
#define EN7572_A2_AW_THLD_LEN		40
#define EN7572_A2_DDM			96	/* 12 bytes: temp/vcc/ibias/txp/rxp/imod */
#define EN7572_A2_DDM_LEN		12
#define EN7572_A2_ALARM_FLAG		112
#define EN7572_A2_WARNING_FLAG		116

/* A2 upper page: MD32 firmware mailbox / calibration mirror (LE u16) */
#define EN7572_MBOX_MAGIC		0x80
#define EN7572_MBOX_FW_VER		0x82
#define EN7572_MBOX_MCU_IDLE		0x83
#define EN7572_MBOX_BOSA_TYPE		0x8b
#define EN7572_MBOX_TSSI_CAL_1		0xb4
#define EN7572_MBOX_RSSI_ADC		0xf2	/* u16 LE */
#define EN7572_MBOX_CHKSUM_ERR		0xf9
#define EN7572_MBOX_LOS_STA		0xfa

/* CSR space (>= 0x100, 32-bit, little-endian, accessed via the A2 client) */
#define EN7572_CSR_APD_DAC		0x15c	/* bit8 APD enable */
#define EN7572_CSR_OCP_CTRL		0x160	/* bit30 OCP enable */
#define EN7572_CSR_RST			0x200	/* bits 30-31 reset pulse */
#define EN7572_CSR_TX_DIS		0x3e0	/* bit9 soft TX_DISABLE, bit8 status */
#define EN7572_CSR_LOS			0x424	/* bit24 LOS */
#define EN7572_CSR_BEN_STS		0x488	/* bit0 BEN status (read only) */

/* MD32 program/data memory download port.
 * Quirk (per the brief): CFG/ADDR go through the A2 client, the DATA
 * port is accessed through the A0 client.
 */
#define EN7572_MD32_PM_CFG		0x3000
#define EN7572_MD32_PM_ADDR		0x3004
#define EN7572_MD32_PM_DATA		0x3008	/* A0 client */
#define EN7572_MD32_DM_CFG		0x300c
#define EN7572_MD32_DM_ADDR		0x3010
#define EN7572_MD32_DM_DATA		0x3014	/* A0 client */
#define EN7572_MD32_EN			0x3018	/* bit0: 1 = run, 0 = halt */

#define EN7572_PM_SIZE			(16 * 1024)
#define EN7572_DM_SIZE			(4 * 1024)
#define EN7572_BOB_SIZE			512	/* A0 page 256B + A2 page 256B */
#define EN7572_BOB_DM_OFFSET		0x600	/* BoB lives at DM offset 0x600 */
#define EN7572_BOB_A2_BASE		256

/* SFF-8472 A0 vendor fields inside the BoB blob */
#define EN7572_BOB_VENDOR_NAME		20	/* 16 bytes */
#define EN7572_BOB_VENDOR_PN		40	/* 16 bytes */

#define EN7572_FW_PM			"airoha/en7572/A60993.elf.pm"
#define EN7572_FW_DM			"airoha/en7572/A60993.elf.dm"

#define EN7572_I2C_MAX_DATA		40	/* largest single block xfer */

#define EN7572_FW_READY_POLL_US		10000
#define EN7572_FW_READY_TIMEOUT_US	(2 * USEC_PER_SEC)

struct en7572 {
	struct i2c_client *a0;		/* 0x50, bound by the i2c core */
	struct i2c_client *a2;		/* 0x51, dummy client */
	struct gpio_desc *tx_disable;
	struct device *hwmon;
	struct dentry *debugfs;
	u32 dbg_csr_addr;
	struct mutex lock;		/* serializes I2C transactions */

	u16 chip_id;
	u16 chip_rev;
	u8 fw_version;
	bool bob_a0_valid;
	bool bob_a2_valid;
	u8 *bob;			/* 512-byte working copy */
	bool burst_armed;
};

/* Default SFF-8472 A2 alarm/warning thresholds (written when the BoB
 * leaves the threshold block erased).  Values are a protocol fact of
 * the vendor init sequence.
 */
static const u8 en7572_aw_thld_default[EN7572_A2_AW_THLD_LEN] = {
	0x64, 0x00, 0xce, 0x00, 0x64, 0x00, 0xce, 0x00,
	0x90, 0x88, 0x71, 0x48, 0x8e, 0x94, 0x73, 0x3c,
	0xa6, 0x05, 0x01, 0xf4, 0x9c, 0x40, 0x02, 0xee,
	0xff, 0xff, 0x00, 0x00, 0xff, 0xff, 0x00, 0x00,
	0x31, 0x24, 0x00, 0x01, 0x27, 0x10, 0x00, 0x03,
};

/* ------------------------------------------------------------------ */
/* I2C access layer                                                    */
/* ------------------------------------------------------------------ */

static int __en7572_read(struct i2c_client *client, u16 reg, u8 *buf,
			 size_t len)
{
	/*
	 * TODO(brief unknown 1): the on-the-wire order of the 2-byte
	 * register address is unconfirmed (the vendor host I2C driver is
	 * closed source).  MSB-first is assumed here; verify on real
	 * hardware with i2ctrace / a logic analyser.
	 */
	u8 addr[2] = { reg >> 8, reg & 0xff };
	struct i2c_msg msgs[] = {
		{
			.addr = client->addr,
			.flags = 0,
			.len = sizeof(addr),
			.buf = addr,
		}, {
			.addr = client->addr,
			.flags = I2C_M_RD,
			.len = len,
			.buf = buf,
		},
	};
	int ret;

	ret = i2c_transfer(client->adapter, msgs, ARRAY_SIZE(msgs));
	return ret == ARRAY_SIZE(msgs) ? 0 : ret < 0 ? ret : -EIO;
}

static int __en7572_write(struct i2c_client *client, u16 reg, const u8 *buf,
			  size_t len)
{
	u8 data[2 + EN7572_I2C_MAX_DATA];
	struct i2c_msg msg = {
		.addr = client->addr,
		.flags = 0,
		.len = 2 + len,
		.buf = data,
	};
	int ret;

	if (len > EN7572_I2C_MAX_DATA)
		return -EINVAL;

	/* TODO(brief unknown 1): address byte order, see __en7572_read() */
	data[0] = reg >> 8;
	data[1] = reg & 0xff;
	memcpy(&data[2], buf, len);

	ret = i2c_transfer(client->adapter, &msg, 1);
	return ret == 1 ? 0 : ret < 0 ? ret : -EIO;
}

static int en7572_read(struct en7572 *priv, struct i2c_client *client,
		       u16 reg, u8 *buf, size_t len)
{
	int ret;

	mutex_lock(&priv->lock);
	ret = __en7572_read(client, reg, buf, len);
	mutex_unlock(&priv->lock);
	return ret;
}

static int en7572_write(struct en7572 *priv, struct i2c_client *client,
			u16 reg, const u8 *buf, size_t len)
{
	int ret;

	mutex_lock(&priv->lock);
	ret = __en7572_write(client, reg, buf, len);
	mutex_unlock(&priv->lock);
	return ret;
}

static int en7572_a2_read8(struct en7572 *priv, u16 reg, u8 *val)
{
	return en7572_read(priv, priv->a2, reg, val, 1);
}

/* Mailbox area (A2 0x80-0xff and calibration words): u16 little-endian */
static int en7572_a2_read16le(struct en7572 *priv, u16 reg, u16 *val)
{
	u8 buf[2];
	int ret;

	ret = en7572_read(priv, priv->a2, reg, buf, sizeof(buf));
	if (!ret)
		*val = get_unaligned_le16(buf);
	return ret;
}

static int en7572_a2_write16le(struct en7572 *priv, u16 reg, u16 val)
{
	u8 buf[2];

	put_unaligned_le16(val, buf);
	return en7572_write(priv, priv->a2, reg, buf, sizeof(buf));
}

/* SFF-8472 standard area (A2 0x00-0x75): u16 big-endian */
static int __maybe_unused en7572_a2_read16be(struct en7572 *priv, u16 reg,
					     u16 *val)
{
	u8 buf[2];
	int ret;

	ret = en7572_read(priv, priv->a2, reg, buf, sizeof(buf));
	if (!ret)
		*val = get_unaligned_be16(buf);
	return ret;
}

/*
 * CSR space (>= 0x100): 32-bit little-endian words, reached through the
 * A2 client.
 *
 * TODO(brief unknown 11): whether 0x50 and 0x51 are fully equivalent
 * for addresses >= 0x100 is unconfirmed; the vendor always uses 0x51
 * for CSR/CFG/ADDR and 0x50 only for the MD32 DATA port, so we keep
 * that split.
 */
static int en7572_csr_read(struct en7572 *priv, u16 reg, u32 *val)
{
	u8 buf[4];
	int ret;

	ret = en7572_read(priv, priv->a2, reg, buf, sizeof(buf));
	if (!ret)
		*val = get_unaligned_le32(buf);
	return ret;
}

static int en7572_csr_write(struct en7572 *priv, u16 reg, u32 val)
{
	u8 buf[4];

	put_unaligned_le32(val, buf);
	return en7572_write(priv, priv->a2, reg, buf, sizeof(buf));
}

static int en7572_csr_update(struct en7572 *priv, u16 reg, u32 mask, u32 val)
{
	u8 buf[4];
	u32 tmp;
	int ret;

	mutex_lock(&priv->lock);
	ret = __en7572_read(priv->a2, reg, buf, sizeof(buf));
	if (ret)
		goto out;
	tmp = get_unaligned_le32(buf);
	tmp = (tmp & ~mask) | (val & mask);
	put_unaligned_le32(tmp, buf);
	ret = __en7572_write(priv->a2, reg, buf, sizeof(buf));
out:
	mutex_unlock(&priv->lock);
	return ret;
}

/* ------------------------------------------------------------------ */
/* MD32 firmware / BoB loading                                         */
/* ------------------------------------------------------------------ */

/*
 * Load @len bytes through one MD32 download port (CFG/ADDR via A2, DATA
 * via A0) and spot-check the first and last word by reading them back.
 */
static int en7572_md32_load(struct en7572 *priv, u16 cfg, u16 addr_reg,
			    u16 data_reg, u32 base, const u8 *data,
			    size_t len)
{
	struct device *dev = &priv->a0->dev;
	unsigned int i, nwords = DIV_ROUND_UP(len, 4);
	u8 word[4];
	int ret;

	/*
	 * TODO(brief unknown 2): the vendor always writes the DATA port
	 * one 4-byte word per transaction and address auto-increment is
	 * only inferred from ADDR being programmed once.  Whether the
	 * port accepts multi-byte block writes is unconfirmed; keep
	 * 4-byte transactions until tested on hardware (a working block
	 * write would cut the ~4 s load time to milliseconds).
	 */
	ret = en7572_csr_update(priv, cfg, BIT(0), BIT(0));
	if (ret)
		return ret;
	ret = en7572_csr_write(priv, addr_reg, base);
	if (ret)
		return ret;

	for (i = 0; i < nwords; i++) {
		size_t off = i * 4;

		memset(word, 0xff, sizeof(word));
		memcpy(word, data + off, min_t(size_t, 4, len - off));
		ret = en7572_write(priv, priv->a0, data_reg, word,
				   sizeof(word));
		if (ret)
			return dev_err_probe(dev, ret,
					     "MD32 data port write failed at word %u\n",
					     i);
	}

	/* Spot-check: read back first and last word (ADDR set the same
	 * way the vendor's save-to-flash path reads the BoB back).
	 */
	ret = en7572_csr_write(priv, addr_reg, base);
	if (ret)
		return ret;
	ret = en7572_read(priv, priv->a0, data_reg, word, sizeof(word));
	if (ret)
		return ret;
	if (memcmp(word, data, min_t(size_t, 4, len))) {
		dev_err(dev, "MD32 load verify failed at first word (base 0x%x)\n",
			base);
		return -EIO;
	}

	if (nwords > 1) {
		size_t off = (nwords - 1) * 4;

		ret = en7572_csr_write(priv, addr_reg, base + off);
		if (ret)
			return ret;
		ret = en7572_read(priv, priv->a0, data_reg, word,
				  sizeof(word));
		if (ret)
			return ret;
		if (memcmp(word, data + off, min_t(size_t, 4, len - off))) {
			dev_err(dev, "MD32 load verify failed at last word (base 0x%x)\n",
				base);
			return -EIO;
		}
	}

	return 0;
}

static int en7572_request_fw(struct en7572 *priv, const char *name,
			     size_t max, const u8 **data, size_t *len)
{
	struct device *dev = &priv->a0->dev;
	const struct firmware *fw;
	u8 *buf;
	int ret;

	ret = request_firmware(&fw, name, dev);
	if (ret)
		return dev_err_probe(dev, ret, "failed to request %s\n", name);

	/*
	 * TODO(brief unknown 10): the vendor truncates the image to a
	 * fixed 16 KiB (PM) / 4 KiB (DM) buffer without checking whether
	 * the tail carries a payload; follow suit until confirmed.
	 */
	*len = min_t(size_t, fw->size, max);
	if (fw->size > max)
		dev_warn(dev, "%s: %zu bytes exceed %zu-byte buffer, truncating\n",
			 name, fw->size, max);

	buf = kmemdup(fw->data, *len, GFP_KERNEL);
	release_firmware(fw);
	if (!buf)
		return -ENOMEM;

	*data = buf;
	return 0;
}

/* ------------------------------------------------------------------ */
/* BoB calibration blob                                                */
/* ------------------------------------------------------------------ */

static bool en7572_bob_page_valid(const u8 *page)
{
	/*
	 * TODO(brief unknown 5): the "page valid" rule (upper half
	 * 0x80-0xff not entirely 0xff) is inferred from the reference
	 * system's "A0=empty A2=valid" message, not from vendor code;
	 * the legal value set of MAGIC_NUM (A2 0x80, 0x73 in the sample)
	 * is likewise unconfirmed.  Verify on real hardware.
	 */
	const u8 *upper = page + 0x80;
	int i;

	for (i = 0; i < 0x80; i++)
		if (upper[i] != 0xff)
			return true;
	return false;
}

static int en7572_read_bob(struct en7572 *priv)
{
	struct device *dev = &priv->a0->dev;
	struct nvmem_cell *cell;
	size_t len = 0;
	void *buf;
	int ret;

	cell = devm_nvmem_cell_get(dev, "calibration");
	if (IS_ERR(cell)) {
		ret = PTR_ERR(cell);
		dev_warn(dev, "no BoB calibration nvmem cell (%pe), continuing without it\n",
			 ERR_PTR(ret));
		return ret;
	}
	buf = nvmem_cell_read(cell, &len);
	if (IS_ERR(buf))
		return PTR_ERR(buf);

	if (len < EN7572_BOB_SIZE)
		dev_warn(dev, "BoB calibration cell too small (%zu < %u)\n",
			 len, EN7572_BOB_SIZE);

	priv->bob = devm_kmalloc(dev, EN7572_BOB_SIZE, GFP_KERNEL);
	if (!priv->bob) {
		kfree(buf);
		return -ENOMEM;
	}
	memset(priv->bob, 0xff, EN7572_BOB_SIZE);
	memcpy(priv->bob, buf, min_t(size_t, len, EN7572_BOB_SIZE));
	kfree(buf);

	priv->bob_a0_valid = en7572_bob_page_valid(priv->bob);
	priv->bob_a2_valid = en7572_bob_page_valid(priv->bob +
						   EN7572_BOB_A2_BASE);

	/*
	 * TX DDMI fallback: if the A0 copy of the first TSSI calibration
	 * pair is erased, fill it from the A2 page.  The vendor performs
	 * this copy only after the BoB has already been loaded into the
	 * MD32 (RAM buffer only, effect doubtful); do it before loading
	 * so it actually takes effect.
	 */
	if (!memcmp(priv->bob + EN7572_MBOX_TSSI_CAL_1, "\xff\xff\xff\xff", 4) &&
	    priv->bob_a2_valid)
		memcpy(priv->bob + EN7572_MBOX_TSSI_CAL_1,
		       priv->bob + EN7572_BOB_A2_BASE + EN7572_MBOX_TSSI_CAL_1,
		       4);

	/* SFF-8472 vendor name / part number, as the vendor init does */
	memcpy(priv->bob + EN7572_BOB_VENDOR_NAME, "ECONET          ", 16);
	memcpy(priv->bob + EN7572_BOB_VENDOR_PN, "EN7572          ", 16);

	dev_info(dev, "BoB calibration: A0 %s, A2 %s\n",
		 priv->bob_a0_valid ? "valid" : "empty",
		 priv->bob_a2_valid ? "valid" : "empty");
	if (!priv->bob_a0_valid)
		dev_info(dev, "A0 page empty: 10G-EPON preparation is blocked\n");

	return 0;
}

/* ------------------------------------------------------------------ */
/* DDM (digital diagnostics)                                           */
/* ------------------------------------------------------------------ */

static int en7572_read_ddm(struct en7572 *priv, u8 buf[EN7572_A2_DDM_LEN])
{
	/* One 12-byte block read at A2@96 updates all channels */
	return en7572_read(priv, priv->a2, EN7572_A2_DDM, buf,
			   EN7572_A2_DDM_LEN);
}

/* 1000 * log10(raw) for raw > 0, decade scaling + binary squaring */
static int en7572_log10_milli(u32 raw)
{
	u64 y = raw;
	int e = 0, f = 0, i;

	while (y < 1000000) {
		y *= 10;
		e -= 1000;
	}
	while (y >= 10000000) {
		y /= 10;
		e += 1000;
	}
	e += 6000;

	for (i = 0; i < 12; i++) {
		y = y * y / 1000000;
		if (y >= 10000000) {
			y /= 10;
			f += 4096 >> (i + 1);
		}
	}

	return e + (f * 1000 + 2048) / 4096;
}

/*
 * SFF-8472 optical power raw is in 0.1 uW units, so
 * dBm = 10 * log10(raw / 10000); returns centi-dBm.
 */
static int en7572_power_centi_dbm(u16 raw)
{
	if (!raw)
		return INT_MIN;
	return en7572_log10_milli(raw) - 4000;
}

/* ------------------------------------------------------------------ */
/* hwmon                                                               */
/* ------------------------------------------------------------------ */

static int en7572_hwmon_read(struct device *dev, enum hwmon_sensor_types type,
			     u32 attr, int channel, long *val)
{
	struct en7572 *priv = dev_get_drvdata(dev);
	u8 buf[EN7572_A2_DDM_LEN];
	int ret;

	if (attr != hwmon_temp_input && attr != hwmon_in_input &&
	    attr != hwmon_curr_input && attr != hwmon_power_input)
		return -EOPNOTSUPP;

	ret = en7572_read_ddm(priv, buf);
	if (ret)
		return ret;

	switch (type) {
	case hwmon_temp:
		/* s16 / 256 degC -> m°C */
		*val = ((s16)get_unaligned_be16(&buf[0]) * 125) / 32;
		break;
	case hwmon_in:
		/* 100 uV units -> mV */
		*val = get_unaligned_be16(&buf[2]) / 10;
		break;
	case hwmon_curr:
		/* 2 uA units -> mA */
		*val = DIV_ROUND_CLOSEST(get_unaligned_be16(&buf[4]), 500);
		break;
	case hwmon_power:
		/* 0.1 uW units -> uW; power1 = TX, power2 = RX */
		*val = DIV_ROUND_CLOSEST(get_unaligned_be16(&buf[6 + channel * 2]),
					 10);
		break;
	default:
		return -EOPNOTSUPP;
	}

	return 0;
}

static umode_t en7572_hwmon_is_visible(const void *data,
				       enum hwmon_sensor_types type, u32 attr,
				       int channel)
{
	return 0444;
}

static const struct hwmon_channel_info * const en7572_hwmon_info[] = {
	HWMON_CHANNEL_INFO(temp, HWMON_T_INPUT),
	HWMON_CHANNEL_INFO(in, HWMON_I_INPUT),
	HWMON_CHANNEL_INFO(curr, HWMON_C_INPUT),
	HWMON_CHANNEL_INFO(power, HWMON_P_INPUT, HWMON_P_INPUT),
	NULL
};

static const struct hwmon_ops en7572_hwmon_ops = {
	.is_visible = en7572_hwmon_is_visible,
	.read = en7572_hwmon_read,
};

static const struct hwmon_chip_info en7572_hwmon_chip_info = {
	.ops = &en7572_hwmon_ops,
	.info = en7572_hwmon_info,
};

/* ------------------------------------------------------------------ */
/* sysfs "frontend" attribute group (mirrors the reference ponctl      */
/* frontend output field names)                                        */
/* ------------------------------------------------------------------ */

static ssize_t chip_id_show(struct device *dev, struct device_attribute *attr,
			    char *buf)
{
	struct en7572 *priv = dev_get_drvdata(dev);

	return sysfs_emit(buf, "0x%04x\n", priv->chip_id);
}
static DEVICE_ATTR_RO(chip_id);

static ssize_t chip_rev_show(struct device *dev, struct device_attribute *attr,
			     char *buf)
{
	struct en7572 *priv = dev_get_drvdata(dev);

	return sysfs_emit(buf, "0x%04x\n", priv->chip_rev);
}
static DEVICE_ATTR_RO(chip_rev);

static ssize_t fw_version_show(struct device *dev,
			       struct device_attribute *attr, char *buf)
{
	struct en7572 *priv = dev_get_drvdata(dev);

	return sysfs_emit(buf, "0x%02x\n", priv->fw_version);
}
static DEVICE_ATTR_RO(fw_version);

static ssize_t mcu_idle_show(struct device *dev,
			     struct device_attribute *attr, char *buf)
{
	struct en7572 *priv = dev_get_drvdata(dev);
	u8 val;
	int ret;

	ret = en7572_a2_read8(priv, EN7572_MBOX_MCU_IDLE, &val);
	if (ret)
		return ret;
	return sysfs_emit(buf, "0x%02x\n", val);
}
static DEVICE_ATTR_RO(mcu_idle);

static ssize_t los_status_show(struct device *dev,
			       struct device_attribute *attr, char *buf)
{
	struct en7572 *priv = dev_get_drvdata(dev);
	u8 val;
	int ret;

	ret = en7572_a2_read8(priv, EN7572_MBOX_LOS_STA, &val);
	if (ret)
		return ret;
	return sysfs_emit(buf, "0x%02x\n", val);
}
static DEVICE_ATTR_RO(los_status);

static ssize_t rssi_adc_show(struct device *dev,
			     struct device_attribute *attr, char *buf)
{
	struct en7572 *priv = dev_get_drvdata(dev);
	u16 val;
	int ret;

	ret = en7572_a2_read16le(priv, EN7572_MBOX_RSSI_ADC, &val);
	if (ret)
		return ret;
	return sysfs_emit(buf, "0x%04x\n", val);
}
static DEVICE_ATTR_RO(rssi_adc);

static ssize_t rx_power_8472_show(struct device *dev,
				  struct device_attribute *attr, char *buf)
{
	struct en7572 *priv = dev_get_drvdata(dev);
	u8 ddm[EN7572_A2_DDM_LEN];
	int ret;

	ret = en7572_read_ddm(priv, ddm);
	if (ret)
		return ret;
	return sysfs_emit(buf, "0x%04x\n", get_unaligned_be16(&ddm[8]));
}
static DEVICE_ATTR_RO(rx_power_8472);

static ssize_t rx_power_dbm_show(struct device *dev,
				 struct device_attribute *attr, char *buf)
{
	struct en7572 *priv = dev_get_drvdata(dev);
	u8 ddm[EN7572_A2_DDM_LEN];
	int ret, cdbm;
	u32 mag;

	ret = en7572_read_ddm(priv, ddm);
	if (ret)
		return ret;

	cdbm = en7572_power_centi_dbm(get_unaligned_be16(&ddm[8]));
	if (cdbm == INT_MIN)
		return sysfs_emit(buf, "-inf\n");
	mag = cdbm < 0 ? -cdbm : cdbm;
	return sysfs_emit(buf, "%s%u.%02u\n", cdbm < 0 ? "-" : "",
			  mag / 100, mag % 100);
}
static DEVICE_ATTR_RO(rx_power_dbm);

static ssize_t line_mode_show(struct device *dev,
			      struct device_attribute *attr, char *buf)
{
	struct en7572 *priv = dev_get_drvdata(dev);
	const char *mode = "none";

	if (priv->bob_a2_valid)
		mode = "xgpon-a2";
	else if (priv->bob_a0_valid)
		mode = "epon-a0";
	return sysfs_emit(buf, "%s\n", mode);
}
static DEVICE_ATTR_RO(line_mode);

static ssize_t bob_a0_valid_show(struct device *dev,
				 struct device_attribute *attr, char *buf)
{
	struct en7572 *priv = dev_get_drvdata(dev);

	return sysfs_emit(buf, "%d\n", priv->bob_a0_valid);
}
static DEVICE_ATTR_RO(bob_a0_valid);

static ssize_t bob_a2_valid_show(struct device *dev,
				 struct device_attribute *attr, char *buf)
{
	struct en7572 *priv = dev_get_drvdata(dev);

	return sysfs_emit(buf, "%d\n", priv->bob_a2_valid);
}
static DEVICE_ATTR_RO(bob_a2_valid);

static ssize_t tx_disable_present_show(struct device *dev,
				       struct device_attribute *attr, char *buf)
{
	struct en7572 *priv = dev_get_drvdata(dev);

	return sysfs_emit(buf, "%d\n", !!priv->tx_disable);
}
static DEVICE_ATTR_RO(tx_disable_present);

static ssize_t tx_disable_asserted_show(struct device *dev,
					struct device_attribute *attr,
					char *buf)
{
	struct en7572 *priv = dev_get_drvdata(dev);

	if (!priv->tx_disable)
		return sysfs_emit(buf, "0\n");
	return sysfs_emit(buf, "%d\n",
			  !!gpiod_get_value_cansleep(priv->tx_disable));
}
static DEVICE_ATTR_RO(tx_disable_asserted);

static ssize_t burst_tx_show(struct device *dev,
			     struct device_attribute *attr, char *buf)
{
	struct en7572 *priv = dev_get_drvdata(dev);

	return sysfs_emit(buf, "%s\n",
			  priv->burst_armed ? "enabled" : "disabled");
}
static DEVICE_ATTR_RO(burst_tx);

static struct attribute *en7572_frontend_attrs[] = {
	&dev_attr_chip_id.attr,
	&dev_attr_chip_rev.attr,
	&dev_attr_fw_version.attr,
	&dev_attr_mcu_idle.attr,
	&dev_attr_los_status.attr,
	&dev_attr_rssi_adc.attr,
	&dev_attr_rx_power_8472.attr,
	&dev_attr_rx_power_dbm.attr,
	&dev_attr_line_mode.attr,
	&dev_attr_bob_a0_valid.attr,
	&dev_attr_bob_a2_valid.attr,
	&dev_attr_tx_disable_present.attr,
	&dev_attr_tx_disable_asserted.attr,
	&dev_attr_burst_tx.attr,
	NULL
};

static const struct attribute_group en7572_frontend_group = {
	.name = "frontend",
	.attrs = en7572_frontend_attrs,
};

/* ------------------------------------------------------------------ */
/* debugfs (read-only raw dumps + CSR read)                            */
/* ------------------------------------------------------------------ */

static int en7572_dump_page(struct seq_file *s, struct i2c_client *client)
{
	struct en7572 *priv = s->private;
	u8 buf[256];
	int i, ret;

	for (i = 0; i < 256; i += 32) {
		ret = en7572_read(priv, client, i, buf + i, 32);
		if (ret)
			return ret;
	}
	seq_hex_dump(s, "", DUMP_PREFIX_OFFSET, 16, 1, buf, sizeof(buf),
		     false);
	return 0;
}

static int en7572_a0_dump_show(struct seq_file *s, void *unused)
{
	struct en7572 *priv = s->private;

	return en7572_dump_page(s, priv->a0);
}
DEFINE_SHOW_ATTRIBUTE(en7572_a0_dump);

static int en7572_a2_dump_show(struct seq_file *s, void *unused)
{
	struct en7572 *priv = s->private;

	return en7572_dump_page(s, priv->a2);
}
DEFINE_SHOW_ATTRIBUTE(en7572_a2_dump);

static int en7572_csr_value_show(struct seq_file *s, void *unused)
{
	struct en7572 *priv = s->private;
	u32 val;
	int ret;

	ret = en7572_csr_read(priv, priv->dbg_csr_addr, &val);
	if (ret)
		return ret;
	seq_printf(s, "0x%08x\n", val);
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(en7572_csr_value);

static void en7572_debugfs_init(struct en7572 *priv)
{
	priv->debugfs = debugfs_create_dir("airoha-en7572", NULL);
	debugfs_create_file("a0_dump", 0444, priv->debugfs, priv,
			    &en7572_a0_dump_fops);
	debugfs_create_file("a2_dump", 0444, priv->debugfs, priv,
			    &en7572_a2_dump_fops);
	/* CSR read: write the address to csr_addr, read csr_value */
	debugfs_create_x32("csr_addr", 0600, priv->debugfs,
			   &priv->dbg_csr_addr);
	debugfs_create_file("csr_value", 0444, priv->debugfs, priv,
			    &en7572_csr_value_fops);
}

/* ------------------------------------------------------------------ */
/* Exported interface for the xPON MAC driver                          */
/* ------------------------------------------------------------------ */

static struct en7572 *en7572_glb;

/**
 * en7572_get_los() - hardware LOS status of the optical frontend
 *
 * Return: 0 = signal present, 1 = loss of signal, negative errno if the
 * frontend is not available or the read failed.
 */
int en7572_get_los(void)
{
	struct en7572 *priv = en7572_glb;
	u32 val;
	int ret;

	if (!priv)
		return -ENODEV;

	ret = en7572_csr_read(priv, EN7572_CSR_LOS, &val);
	if (ret)
		return ret;
	return !!(val & BIT(24));
}
EXPORT_SYMBOL_GPL(en7572_get_los);

/**
 * en7572_burst_gate() - arm/disarm burst transmission
 * @arm: true to allow the laser to be burst-gated by the MAC/PHY
 *
 * Arming releases the two software gates (soft TX_DISABLE CSR bit and
 * the board TX_DISABLE GPIO).  BEN itself is driven by the PON PHY
 * burst logic; this driver only observes its status (CSR 0x488 bit0).
 */
int en7572_burst_gate(bool arm)
{
	struct en7572 *priv = en7572_glb;
	int ret;

	if (!priv)
		return -ENODEV;

	if (arm) {
		/*
		 * TODO(brief unknown 6): the exact actions of the
		 * reference 6.18 driver when the gate is armed are
		 * unconfirmed (GPIO deassert timing, whether CSR 0x100
		 * bits 2-3 are written, whether soft TX_DIS is touched).
		 * Releasing soft TX_DIS and the GPIO is the minimal
		 * safe set; revisit with on-hardware experiments.
		 */
		ret = en7572_csr_update(priv, EN7572_CSR_TX_DIS, BIT(9), 0);
		if (ret)
			return ret;
		if (priv->tx_disable)
			gpiod_set_value_cansleep(priv->tx_disable, 0);
		priv->burst_armed = true;
	} else {
		if (priv->tx_disable)
			gpiod_set_value_cansleep(priv->tx_disable, 1);
		ret = en7572_csr_update(priv, EN7572_CSR_TX_DIS, BIT(9),
					BIT(9));
		if (ret)
			return ret;
		priv->burst_armed = false;
	}

	return 0;
}
EXPORT_SYMBOL_GPL(en7572_burst_gate);

/**
 * en7572_set_tx_mode() - select TX eye / line mode
 * @mode: 0 = XGPON (BoB A2 page), 1 = 10G-EPON direction (BoB A0 page)
 *
 * TODO: not implemented.  The vendor equivalent applies calibration
 * words from the selected BoB page to the analog CSRs (DCL_CTRL_2,
 * 0x124, 0x128, 0x130, 0x13c, TSSI calibration) and restores BEN via
 * CSR 0x100 bits 2-3.  Needed only when the A0 page carries valid
 * calibration; on XG2010G the A0 page is empty.
 */
int en7572_set_tx_mode(int mode)
{
	if (!en7572_glb)
		return -ENODEV;
	if (mode != 0)
		return -EOPNOTSUPP;
	return 0;
}
EXPORT_SYMBOL_GPL(en7572_set_tx_mode);

/* ------------------------------------------------------------------ */
/* probe / remove                                                      */
/* ------------------------------------------------------------------ */

static u8 en7572_read_fw_ver(struct en7572 *priv)
{
	u8 val = 0xff;

	/* keep polling on I2C errors; the timeout distinguishes them */
	en7572_a2_read8(priv, EN7572_MBOX_FW_VER, &val);
	return val;
}

static int en7572_init_hw(struct en7572 *priv)
{
	struct device *dev = &priv->a0->dev;
	const u8 *pm = NULL, *dm = NULL;
	size_t pm_len = 0, dm_len = 0;
	u16 chip_info;
	u8 val, fw_ver;
	int ret;

	/* step 1: identify */
	ret = en7572_a2_read16le(priv, EN7572_REG_CHIP_ID, &priv->chip_id);
	if (ret)
		return dev_err_probe(dev, ret, "chip ID read failed\n");
	if (priv->chip_id != EN7572_CHIP_ID)
		return dev_err_probe(dev, -ENODEV,
				     "unexpected chip ID 0x%04x (want 0x%04x)\n",
				     priv->chip_id, EN7572_CHIP_ID);
	if (!en7572_a2_read16le(priv, EN7572_REG_CHIP_INFO, &chip_info))
		dev_dbg(dev, "chip info word 0x%04x\n", chip_info);
	/*
	 * TODO(brief unknown 4): the source register of chip_rev
	 * (0x04e2 on the reference system) is unknown; scan A2
	 * 0x400-0x410 on real hardware.  Report 0 until then.
	 */
	priv->chip_rev = 0;

	/* step 2: halt MD32, disable OCP and APD */
	ret = en7572_csr_update(priv, EN7572_MD32_EN, BIT(0), 0);
	if (ret)
		return dev_err_probe(dev, ret, "MD32 halt failed\n");
	ret = en7572_csr_update(priv, EN7572_CSR_OCP_CTRL, BIT(30), 0);
	if (ret)
		return dev_err_probe(dev, ret, "OCP disable failed\n");
	ret = en7572_csr_update(priv, EN7572_CSR_APD_DAC, BIT(8), 0);
	if (ret)
		return dev_err_probe(dev, ret, "APD disable failed\n");
	msleep(100);

	/* step 3: reset pulse (CSR 0x200 bits 30-31: 0 -> 3) */
	ret = en7572_csr_update(priv, EN7572_CSR_RST, GENMASK(31, 30), 0);
	if (ret)
		return dev_err_probe(dev, ret, "reset assert failed\n");
	ret = en7572_csr_update(priv, EN7572_CSR_RST, GENMASK(31, 30),
				FIELD_PREP(GENMASK(31, 30), 3));
	if (ret)
		return dev_err_probe(dev, ret, "reset release failed\n");

	/* step 4: fetch PM / DM firmware images (raw binary streams,
	 * despite the .elf suffix)
	 *
	 * TODO(brief unknown 7): the shipped images carry firmware
	 * version 0x27 (dm[0] is suspected to be the version byte),
	 * while the reference system runs fw 0x2a; that image is not
	 * available yet.
	 */
	ret = en7572_request_fw(priv, EN7572_FW_PM, EN7572_PM_SIZE,
				&pm, &pm_len);
	if (ret)
		return ret;
	ret = en7572_request_fw(priv, EN7572_FW_DM, EN7572_DM_SIZE,
				&dm, &dm_len);
	if (ret)
		goto out_free;

	/* step 5: BoB calibration blob (non-fatal if absent) */
	en7572_read_bob(priv);

	/* steps 6-8: load PM, DM, then the BoB at DM offset 0x600,
	 * each followed by a read-back spot check
	 */
	ret = en7572_md32_load(priv, EN7572_MD32_PM_CFG, EN7572_MD32_PM_ADDR,
			       EN7572_MD32_PM_DATA, 0, pm, pm_len);
	if (ret) {
		dev_err_probe(dev, ret, "PM load failed\n");
		goto out_free;
	}
	ret = en7572_md32_load(priv, EN7572_MD32_DM_CFG, EN7572_MD32_DM_ADDR,
			       EN7572_MD32_DM_DATA, 0, dm, dm_len);
	if (ret) {
		dev_err_probe(dev, ret, "DM load failed\n");
		goto out_free;
	}
	if (priv->bob) {
		ret = en7572_md32_load(priv, EN7572_MD32_DM_CFG,
				       EN7572_MD32_DM_ADDR,
				       EN7572_MD32_DM_DATA,
				       EN7572_BOB_DM_OFFSET,
				       priv->bob, EN7572_BOB_SIZE);
		if (ret) {
			dev_err_probe(dev, ret, "BoB load failed\n");
			goto out_free;
		}
	}

	/* step 9: A/W threshold fallback (erased threshold block) */
	{
		u8 thld[4];

		ret = en7572_read(priv, priv->a2, EN7572_A2_AW_THLD, thld,
				  sizeof(thld));
		if (ret) {
			dev_err_probe(dev, ret, "A/W threshold read failed\n");
			goto out_free;
		}
		if (!memcmp(thld, "\xff\xff\xff\xff", 4)) {
			dev_info(dev, "A/W thresholds erased, writing defaults\n");
			ret = en7572_write(priv, priv->a2, EN7572_A2_AW_THLD,
					   en7572_aw_thld_default,
					   sizeof(en7572_aw_thld_default));
			if (ret) {
				dev_err_probe(dev, ret,
					      "A/W threshold write failed\n");
				goto out_free;
			}
		}
	}

	/* step 10: clear alarm/warning flags */
	ret = en7572_a2_write16le(priv, EN7572_A2_ALARM_FLAG, 0);
	if (!ret)
		ret = en7572_a2_write16le(priv, EN7572_A2_WARNING_FLAG, 0);
	if (ret) {
		dev_err_probe(dev, ret, "failed to clear alarm flags\n");
		goto out_free;
	}

	/* step 11: start the MD32 */
	ret = en7572_csr_update(priv, EN7572_MD32_EN, BIT(0), BIT(0));
	if (ret) {
		dev_err_probe(dev, ret, "MD32 start failed\n");
		goto out_free;
	}

	/*
	 * step 12: wait for firmware readiness.
	 * TODO(brief unknown 3): the readiness criterion (poll A2 0x82
	 * FW_VER until != 0xff) and the typical boot time are
	 * unconfirmed; the reference system takes roughly 4 s from BoB
	 * load to "MD32 initialized" (dominated by the slow data port
	 * writes, see unknown 2).  Verify on real hardware.
	 */
	{
		ktime_t deadline = ktime_add_us(ktime_get(),
						EN7572_FW_READY_TIMEOUT_US);

		for (;;) {
			fw_ver = en7572_read_fw_ver(priv);
			if (fw_ver != 0xff)
				break;
			if (ktime_after(ktime_get(), deadline)) {
				dev_err_probe(dev, -ETIMEDOUT,
					      "MD32 firmware not ready\n");
				goto out_free;
			}
			usleep_range(EN7572_FW_READY_POLL_US,
				     EN7572_FW_READY_POLL_US * 2);
		}
	}
	priv->fw_version = fw_ver;

	/* TODO(brief unknown 8): CHKSUM_ERR semantics and the firmware's
	 * self-check coverage are unconfirmed; log only.
	 */
	if (!en7572_a2_read8(priv, EN7572_MBOX_CHKSUM_ERR, &val) && val)
		dev_warn(dev, "firmware reports CHKSUM_ERR=0x%02x\n", val);

	/* TODO(brief unknown 9): BOSA_TYPE encoding (sample = 0x01) is
	 * undocumented; logged for diagnosis only.
	 */
	if (!en7572_a2_read8(priv, EN7572_MBOX_BOSA_TYPE, &val))
		dev_dbg(dev, "BOSA_TYPE=0x%02x\n", val);

	/*
	 * TODO(phase2, brief section 6): CUSTOM_FUNC (A2 0xe8) bit0/bit1
	 * select the reduce_imod / adaptive_pav laser-safety policy
	 * threads; postponed, to be implemented with delayed_work.
	 */

	/* keep the laser off until the MAC arms the burst gate */
	ret = en7572_csr_update(priv, EN7572_CSR_TX_DIS, BIT(9), BIT(9));
	if (ret) {
		dev_err_probe(dev, ret, "soft TX_DISABLE failed\n");
		goto out_free;
	}
	if (priv->tx_disable)
		gpiod_set_value_cansleep(priv->tx_disable, 1);

out_free:
	kfree(dm);
	kfree(pm);
	return ret;
}

static int en7572_probe(struct i2c_client *client)
{
	struct device *dev = &client->dev;
	struct en7572 *priv;
	int ret;

	priv = devm_kzalloc(dev, sizeof(*priv), GFP_KERNEL);
	if (!priv)
		return -ENOMEM;
	priv->a0 = client;
	mutex_init(&priv->lock);
	i2c_set_clientdata(client, priv);

	/* assert TX_DISABLE as early as possible: laser stays off */
	priv->tx_disable = devm_gpiod_get_optional(dev, "tx-disable",
						   GPIOD_OUT_HIGH);
	if (IS_ERR(priv->tx_disable))
		return dev_err_probe(dev, PTR_ERR(priv->tx_disable),
				     "failed to get tx-disable GPIO\n");
	if (priv->tx_disable)
		gpiod_set_value_cansleep(priv->tx_disable, 1);

	priv->a2 = devm_i2c_new_dummy_device(dev, client->adapter,
					     EN7572_A2_ADDR);
	if (IS_ERR(priv->a2))
		return dev_err_probe(dev, PTR_ERR(priv->a2),
				     "failed to register A2 (0x%02x) client\n",
				     EN7572_A2_ADDR);

	ret = en7572_init_hw(priv);
	if (ret)
		return ret;

	priv->hwmon = devm_hwmon_device_register_with_info(dev, "en7572", priv,
							   &en7572_hwmon_chip_info,
							   NULL);
	if (IS_ERR(priv->hwmon))
		return dev_err_probe(dev, PTR_ERR(priv->hwmon),
				     "hwmon registration failed\n");

	ret = devm_device_add_group(dev, &en7572_frontend_group);
	if (ret)
		return dev_err_probe(dev, ret,
				     "failed to add frontend sysfs group\n");

	en7572_debugfs_init(priv);

	dev_info(dev, "MD32 initialized, chip=0x%04x rev=0x%04x fw=0x%02x, burst TX held disabled\n",
		 priv->chip_id, priv->chip_rev, priv->fw_version);

	en7572_glb = priv;
	return 0;
}

static void en7572_remove(struct i2c_client *client)
{
	struct en7572 *priv = i2c_get_clientdata(client);

	en7572_glb = NULL;
	debugfs_remove_recursive(priv->debugfs);

	/* laser off, MD32 halted */
	if (priv->tx_disable)
		gpiod_set_value_cansleep(priv->tx_disable, 1);
	en7572_csr_update(priv, EN7572_CSR_TX_DIS, BIT(9), BIT(9));
	en7572_csr_update(priv, EN7572_MD32_EN, BIT(0), 0);
}

static const struct of_device_id en7572_of_match[] = {
	{ .compatible = "airoha,en7572" },
	{ }
};
MODULE_DEVICE_TABLE(of, en7572_of_match);

static struct i2c_driver en7572_driver = {
	.driver = {
		.name = "airoha-en7572",
		.of_match_table = en7572_of_match,
	},
	.probe = en7572_probe,
	.remove = en7572_remove,
};
module_i2c_driver(en7572_driver);

MODULE_DESCRIPTION("Airoha EN7572 BoB optical frontend driver (clean-room)");
MODULE_FIRMWARE(EN7572_FW_PM);
MODULE_FIRMWARE(EN7572_FW_DM);
MODULE_LICENSE("GPL");
