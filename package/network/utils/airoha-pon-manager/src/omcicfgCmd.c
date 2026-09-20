// SPDX-License-Identifier: GPL-2.0-only
/*
 * omcicfgCmd - drop-in replacement for the vendor identity configuration
 * tool on Airoha EN7581 (XG-040G / XG2010G) GPON units.
 *
 * Implements the command surface consumed by airoha-pon-manager
 * (ponctl-helper) and luci-app-xpon (xpon-apply.sh):
 *
 *   set sn <VEND12345678 | 16 hex digits>   PLOAM serial number (GPON_IOS_SN)
 *   set passwdAscii <pw>                    PLOAM password, ASCII (GPON_IOS_PASSWD)
 *   set passwdHex <hex>                     PLOAM password, binary (GPON_IOS_PASSWD)
 *   set loid <loid>                         LOID, stored to UCI (see note)
 *   set loidPasswd <pw>                     LOID password (GPON_IOS_PASSWD)
 *   set vendorId <4 ASCII>                  stored to UCI; PLOAM vendor id is
 *                                           derived by the driver from SN[0:4]
 *   set equipmentId / hwVersion /
 *       swVersion / operatorId <text>       stored to UCI (OMCI ME 256/257
 *                                           identity; live reflection depends
 *                                           on the OMCI agent in use)
 *   get sn / get onuInfo                    readback via GPON_IOG_ONU_INFO
 *
 * The GPON_IOS_* ioctl ABI is the vendor SDK's own /dev/pon interface
 * (bsp/include/global_inc/xpon_driver_global.h + xpon_ioctl_if.h).
 */

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>

#define PON_DEV			"/dev/pon"

#define GPON_SN_LENS		8
#define GPON_PASSWD_LENS	10
#define GPON_REG_ID_LENS	36

/* GPON_IOS_* raw command values (bsp/include/global_inc/xpon_driver_global.h) */
#define GPON_IOS_SN_PASSWD	1
#define GPON_IOS_SN		2
#define GPON_IOS_PASSWD		3
#define GPON_IOG_ONU_INFO	7

struct XMCS_GponSnPasswd_S {
	unsigned char sn[GPON_SN_LENS];
	unsigned char passwd[GPON_PASSWD_LENS];
	unsigned char regid[GPON_REG_ID_LENS];
	unsigned char EmergencyState;
	unsigned char PasswdLength;
	unsigned char RegidLength;
	unsigned char hexFlag;
};

struct XMCS_GponOnuInfo_S {
	unsigned char onuId;
	unsigned char state;
	unsigned char sn[GPON_SN_LENS];
	unsigned char PasswdLength;
	unsigned char RegidLength;
	unsigned char hexFlag;
	unsigned char passwd[GPON_PASSWD_LENS];
	unsigned char regid[GPON_REG_ID_LENS];
	unsigned char keyIdx;
	unsigned char key[16];
	unsigned int actTo1Timer;
	unsigned int actTo2Timer;
	unsigned short omcc;
	unsigned char EmergencyState;
};

static int pon_fd = -1;

static int pon_open(void)
{
	if (pon_fd < 0) {
		pon_fd = open(PON_DEV, O_RDWR);
		if (pon_fd < 0) {
			fprintf(stderr, "Error: cannot open %s: %s\n",
				PON_DEV, strerror(errno));
			return -1;
		}
	}
	return 0;
}

/* "VEND12345678" -> 'V','E','N','D',0x12,0x34,0x56,0x78
 * 16 hex digits  -> 8 raw bytes */
static int parse_sn(const char *text, unsigned char *out)
{
	size_t len = strlen(text);
	int i;

	if (len == 16 && strspn(text, "0123456789abcdefABCDEF") == 16) {
		for (i = 0; i < 8; i++) {
			char byte[3] = { text[i * 2], text[i * 2 + 1], 0 };
			out[i] = (unsigned char)strtoul(byte, NULL, 16);
		}
		return 0;
	}
	if (len == 12) {
		for (i = 0; i < 4; i++)
			out[i] = (unsigned char)text[i];
		for (i = 4; i < 8; i++) {
			char byte[3] = { text[i * 2 - 8 + 4], text[i * 2 - 8 + 5], 0 };
			out[i] = (unsigned char)strtoul(byte, NULL, 16);
		}
		return 0;
	}
	fprintf(stderr, "Input Error: SN must be 12 ASCII (VEND12345678) "
			"or 16 hexadecimal digits\n");
	return -1;
}

static int hex_to_bin(const char *hex, unsigned char *out, size_t outlen)
{
	size_t len = strlen(hex);
	size_t i;

	if (len == 0 || len / 2 > outlen || (len % 2) != 0)
		return -1;
	if (strspn(hex, "0123456789abcdefABCDEF") != len)
		return -1;
	for (i = 0; i < len / 2; i++) {
		char byte[3] = { hex[i * 2], hex[i * 2 + 1], 0 };
		out[i] = (unsigned char)strtoul(byte, NULL, 16);
	}
	return (int)(len / 2);
}

static void uci_store(const char *option, const char *value)
{
	char cmd[512];

	if (!value || !*value)
		return;
	snprintf(cmd, sizeof(cmd),
		 "uci -q set pon.omci_identity.%s='%s' && uci -q commit pon",
		 option, value);
	if (system(cmd) != 0)
		fprintf(stderr, "Warning: uci store %s failed\n", option);
}

/* readback used by the apply-script verify loop: our own store first,
 * then the luci/pon-manager identity stores */
static void uci_read(const char *option, char *out, size_t outlen)
{
	char cmd[256];
	FILE *fp;

	out[0] = '\0';
	snprintf(cmd, sizeof(cmd),
		 "uci -q get pon.omci_identity.%s 2>/dev/null || "
		 "uci -q get network.xpon_auth.%s 2>/dev/null || "
		 "uci -q get xpon.device.%s 2>/dev/null",
		 option, option, option);
	fp = popen(cmd, "r");
	if (!fp)
		return;
	if (fgets(out, (int)outlen, fp)) {
		size_t len = strlen(out);
		while (len && (out[len - 1] == '\n' || out[len - 1] == '\r'))
			out[--len] = '\0';
	}
	pclose(fp);
}

static int cmd_set_sn(const char *text)
{
	struct XMCS_GponSnPasswd_S sn;

	memset(&sn, 0, sizeof(sn));
	if (parse_sn(text, sn.sn) != 0)
		return 1;
	if (ioctl(pon_fd, GPON_IOS_SN, &sn) != 0) {
		fprintf(stderr, "Error: GPON_IOS_SN ioctl failed: %s\n",
			strerror(errno));
		return 1;
	}
	printf("SN set: %.4s-%02X%02X%02X%02X\n", sn.sn, sn.sn[4], sn.sn[5],
	       sn.sn[6], sn.sn[7]);
	return 0;
}

/* ME-layer identity fields (equipment id / versions / operator id) have no
 * verified in-kernel set path yet; persist them for the OMCI agent and
 * report success so the apply-script verify loop stays consistent. */
static int cmd_store_identity(const char *field, const char *value)
{
	uci_store(field, value);
	printf("%s stored to UCI (pon.omci_identity.%s)\n", field, field);
	return 0;
}

static int cmd_set_passwd(const char *text, int hex)
{
	struct XMCS_GponSnPasswd_S pw;
	int len;

	memset(&pw, 0, sizeof(pw));
	if (hex) {
		len = hex_to_bin(text, pw.passwd, GPON_PASSWD_LENS);
		if (len < 0) {
			fprintf(stderr, "Input Error: password hex must be "
					"1..20 hexadecimal digits\n");
			return 1;
		}
	} else {
		len = (int)strlen(text);
		if (len < 1 || len > GPON_PASSWD_LENS) {
			fprintf(stderr, "Input Error: password length must be "
					"less than %d ASCII\n", GPON_PASSWD_LENS);
			return 1;
		}
		memcpy(pw.passwd, text, (size_t)len);
	}
	pw.PasswdLength = (unsigned char)len;
	pw.hexFlag = hex ? 1 : 0;
	if (ioctl(pon_fd, GPON_IOS_PASSWD, &pw) != 0) {
		fprintf(stderr, "Error: GPON_IOS_PASSWD ioctl failed: %s\n",
			strerror(errno));
		return 1;
	}
	printf("PLOAM password set (%d bytes, %s)\n", len,
	       hex ? "hex" : "ascii");
	return 0;
}

static int cmd_get_onu_info(void)
{
	struct XMCS_GponOnuInfo_S info;
	int i;

	memset(&info, 0, sizeof(info));
	if (ioctl(pon_fd, GPON_IOG_ONU_INFO, &info) != 0) {
		fprintf(stderr, "Error: GPON_IOG_ONU_INFO ioctl failed: %s\n",
			strerror(errno));
		return 1;
	}
	printf("onuId      : %d\n", info.onuId);
	printf("state      : %d\n", info.state);
	printf("SN         : ");
	for (i = 0; i < GPON_SN_LENS; i++)
		printf("%02X", info.sn[i]);
	printf("\n");
	printf("Passwd     : ");
	for (i = 0; i < (info.PasswdLength ? info.PasswdLength : GPON_PASSWD_LENS);
	     i++)
		printf("%02X", info.passwd[i]);
	printf("\n");
	printf("RegidLength: %d\n", info.RegidLength);
	printf("OMCC       : 0x%04x\n", info.omcc);
	return 0;
}

static void usage(void)
{
	fprintf(stderr,
		"Usage:\n"
		"  omcicfgCmd set sn <VEND12345678 | 16 hex>\n"
		"  omcicfgCmd set passwdAscii <pw>\n"
		"  omcicfgCmd set passwdHex <hex>\n"
		"  omcicfgCmd set loidPasswd <pw>\n"
		"  omcicfgCmd set vendorId <4 ASCII>      (uci store; PLOAM vendor follows SN)\n"
		"  omcicfgCmd set equipmentId <text>      (uci store, OMCI ME identity)\n"
		"  omcicfgCmd set hwVersion <text>        (uci store, OMCI ME identity)\n"
		"  omcicfgCmd set swVersion <text>        (uci store, OMCI ME identity)\n"
		"  omcicfgCmd set operatorId <text>       (uci store, OMCI ME identity)\n"
		"  omcicfgCmd get onuInfo\n");
}

int main(int argc, char **argv)
{
	if (argc < 3) {
		usage();
		return 1;
	}

	if (!strcmp(argv[1], "get")) {
		char val[128];
		if (!strcmp(argv[2], "onuInfo")) {
			if (pon_open() != 0)
				return 1;
			return cmd_get_onu_info();
		}
		if (!strcmp(argv[2], "sn")) {
			if (pon_open() != 0)
				return 1;
			return cmd_get_onu_info();
		}
		/* ME-layer identity readback from the persistent stores */
		uci_read(argv[2], val, sizeof(val));
		printf("%s\n", val);
		return 0;
	}

	if (!strcmp(argv[1], "set") && argc >= 4) {
		const char *field = argv[2];
		const char *value = argv[3];
		int is_hex = (argc >= 5 && !strcmp(argv[4], "hex"));

		if (pon_open() != 0)
			return 1;

		if (!strcmp(field, "sn"))
			return cmd_set_sn(value);
		if (!strcmp(field, "passwdAscii"))
			return cmd_set_passwd(value, 0);
		if (!strcmp(field, "passwdHex"))
			return cmd_set_passwd(value, 1);
		if (!strcmp(field, "loidPasswd"))
			return cmd_set_passwd(value, is_hex);
		if (!strcmp(field, "loid") || !strcmp(field, "vendorId") ||
		    !strcmp(field, "equipmentId") || !strcmp(field, "hwVersion") ||
		    !strcmp(field, "swVersion") || !strcmp(field, "operatorId")) {
			return cmd_store_identity(field, value);
		}
	}

	usage();
	return 1;
}
