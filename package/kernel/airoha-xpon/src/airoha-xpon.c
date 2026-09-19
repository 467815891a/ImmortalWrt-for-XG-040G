// SPDX-License-Identifier: GPL-2.0-only
/*
 * Clean-room xPON MAC driver for Airoha EN7581 (Gemtek XG2010G).
 *
 * Binds to the "airoha,an7581-xpon-mac" platform node (XG-PON MAC
 * @0x1fb64000, four register banks: gpon/xgpon/epon/pon-phy).
 *
 * Reference material (register/flow level only):
 *  - docs/EN7581_XPON_寄存器地图.md
 *  - reference/xg040gmd-6.18/ (running 6.18 reference system dumps)
 */

#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/of.h>
#include <linux/of_device.h>
#include <linux/io.h>
#include <linux/interrupt.h>
#include <linux/reset.h>
#include <linux/netdevice.h>
#include <linux/nvmem-consumer.h>

#define DRV_NAME	"airoha-xpon"

struct airoha_xpon {
	struct device *dev;
	void __iomem *base[4];		/* gpon, xgpon, epon, pon-phy */
	int irq_mac;
	int irq_phy;
	struct reset_control *rst_mac;
	struct reset_control *rst_phy;
	struct net_device *pon_ndev;	/* data path */
	struct net_device *omci_ndev;	/* OMCI raw-PDU channel */
	struct net_device *oam_ndev;	/* OAM raw-PDU channel */
	u8 serial[12];			/* vendor_id(4) + vs_sn(8) */
	bool serial_valid;
};

static irqreturn_t airoha_xpon_mac_irq(int irq, void *data)
{
	struct airoha_xpon *priv = data;

	/* TODO(phase2): PLOAM/sync/error interrupt handling */
	return IRQ_HANDLED;
}

static irqreturn_t airoha_xpon_phy_irq(int irq, void *data)
{
	struct airoha_xpon *priv = data;

	/* TODO(phase1/2): LOS/sync events from PON PHY */
	return IRQ_HANDLED;
}

static int airoha_xpon_read_serial(struct airoha_xpon *priv)
{
	struct device *dev = priv->dev;
	struct nvmem_cell *cell;
	size_t len = 0;
	void *buf;

	cell = devm_nvmem_cell_get(dev, "pon-serial");
	if (IS_ERR(cell)) {
		dev_warn(dev, "no pon-serial nvmem cell: %pe\n", cell);
		return PTR_ERR(cell);
	}
	buf = nvmem_cell_read(cell, &len);
	if (IS_ERR(buf))
		return PTR_ERR(buf);
	if (len == sizeof(priv->serial)) {
		static const u8 zero_sn[12] = { };

		memcpy(priv->serial, buf, sizeof(priv->serial));
		priv->serial_valid = !!memcmp(priv->serial, zero_sn,
					      sizeof(priv->serial));
	} else {
		dev_warn(dev, "unexpected pon-serial length %zu\n", len);
	}
	kfree(buf);
	return 0;
}

static int airoha_xpon_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct airoha_xpon *priv;
	int i, ret;

	priv = devm_kzalloc(dev, sizeof(*priv), GFP_KERNEL);
	if (!priv)
		return -ENOMEM;
	priv->dev = dev;
	platform_set_drvdata(pdev, priv);

	for (i = 0; i < 4; i++) {
		priv->base[i] = devm_platform_ioremap_resource(pdev, i);
		if (IS_ERR(priv->base[i]))
			return dev_err_probe(dev, PTR_ERR(priv->base[i]),
					     "failed to map reg %d\n", i);
	}

	priv->irq_mac = platform_get_irq_byname(pdev, "mac");
	if (priv->irq_mac < 0)
		return dev_err_probe(dev, priv->irq_mac, "no mac irq\n");
	priv->irq_phy = platform_get_irq_byname(pdev, "phy");
	if (priv->irq_phy < 0)
		return dev_err_probe(dev, priv->irq_phy, "no phy irq\n");

	ret = devm_request_irq(dev, priv->irq_mac, airoha_xpon_mac_irq,
			       0, "airoha-xpon-mac", priv);
	if (ret)
		return dev_err_probe(dev, ret, "request mac irq failed\n");
	ret = devm_request_irq(dev, priv->irq_phy, airoha_xpon_phy_irq,
			       0, "airoha-xpon-phy", priv);
	if (ret)
		return dev_err_probe(dev, ret, "request phy irq failed\n");

	airoha_xpon_read_serial(priv); /* may be overridden via sysfs later */

	/* TODO(phase1/2): netdev registration, PCS attach, PLOAM engine */
	dev_info(dev, "xPON MAC probed (stub): serial %s\n",
		 priv->serial_valid ? "valid" : "invalid/default");
	return 0;
}

static void airoha_xpon_remove(struct platform_device *pdev)
{
}

static const struct of_device_id airoha_xpon_of_match[] = {
	{ .compatible = "airoha,an7581-xpon-mac" },
	{ }
};
MODULE_DEVICE_TABLE(of, airoha_xpon_of_match);

static struct platform_driver airoha_xpon_driver = {
	.probe = airoha_xpon_probe,
	.remove = airoha_xpon_remove,
	.driver = {
		.name = DRV_NAME,
		.of_match_table = airoha_xpon_of_match,
	},
};
module_platform_driver(airoha_xpon_driver);

MODULE_DESCRIPTION("Airoha EN7581 xPON MAC driver (clean-room)");
MODULE_LICENSE("GPL");
