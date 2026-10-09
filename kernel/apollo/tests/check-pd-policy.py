#!/usr/bin/env python3
"""Exercise the patched SMB5 routines with fake TCPM and PMIC interfaces.

Usage: python3 check-pd-policy.py /path/to/patched/linux
Uses the driver's C functions directly, rather than a Python policy model.
The simulated register checks complement a kernel build and an on-phone trial.
"""

import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

tree = Path(sys.argv[1])
driver = (tree / "drivers/power/supply/qcom_pm8150b_charger.c").read_text()
header = (tree / "include/linux/power_supply.h").read_text()


def function(name):
    match = re.search(r"^static [^\n]*\b" + name + r"\(", driver, re.M)
    if not match:
        raise RuntimeError(f"missing driver function: {name}")
    end = driver.index("\n}\n", match.start()) + 3
    return driver[match.start():end]


defines = "\n".join(line for line in driver.splitlines() if line.startswith("#define "))
usb_enum = re.search(r"enum power_supply_usb_type \{.*?\n};", header, re.S).group()
functions = "\n".join(function(name) for name in (
    "smb5_set_current_limit", "smb5_is_pd", "smb5_get_typec_limit", "smb5_apply_input_limit",
    "smb5_set_prop_charging_enabled", "smb5_set_property",
))

shim = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#define BIT(n) (1U << (n))
#define GENMASK(h, l) (((~0U) << (l)) & ((~0U) >> (31 - (h))))
#define clamp(v, l, h) ((v) < (l) ? (l) : ((v) > (h) ? (h) : (v)))
#define dev_err(...) ((void)0)
enum power_supply_property {
    POWER_SUPPLY_PROP_ONLINE, POWER_SUPPLY_PROP_USB_TYPE, POWER_SUPPLY_PROP_CURRENT_NOW,
    POWER_SUPPLY_PROP_CURRENT_MAX, POWER_SUPPLY_PROP_CHARGING_ENABLED
};
union power_supply_propval { int intval; };
struct power_supply { int online, type, budget, fail_property; void *data; };
struct regmap { unsigned int regs[0x2000]; int writes, fail_write; };
struct smb5_chip { struct power_supply *usb_psy; struct regmap *regmap; unsigned int base; };
#define mutex_lock(p) ((void)0)
#define mutex_unlock(p) ((void)0)
static void *power_supply_get_drvdata(struct power_supply *psy) { return psy->data; }
static int smb5_apsd_get_charger_type(struct smb5_chip *chip, int *type)
{
    (void)chip; (void)type;
    return -EAGAIN;
}
static int power_supply_get_property(struct power_supply *psy,
                                    enum power_supply_property prop,
                                    union power_supply_propval *val)
{
    if (psy->fail_property == (int)prop) return -EIO;
    switch (prop) {
    case POWER_SUPPLY_PROP_ONLINE: val->intval = psy->online; break;
    case POWER_SUPPLY_PROP_USB_TYPE: val->intval = psy->type; break;
    case POWER_SUPPLY_PROP_CURRENT_NOW: val->intval = psy->budget; break;
    default: return -EINVAL;
    }
    return 0;
}
static int regmap_write(struct regmap *map, unsigned int reg, unsigned int val)
{
    if (++map->writes == map->fail_write) return -EIO;
    assert(reg < 0x2000);
    map->regs[reg] = val;
    return 0;
}
static int regmap_update_bits(struct regmap *map, unsigned int reg,
                              unsigned int mask, unsigned int val)
{
    return regmap_write(map, reg, (map->regs[reg] & ~mask) | (val & mask));
}
'''

tests = r'''
static unsigned int cases;
static void exercise(int online, int type, int advertised, unsigned int expected,
                     bool controlled)
{
    struct power_supply psy = {online, type, advertised, -1, NULL};
    struct regmap map = {0};
    struct smb5_chip chip = {&psy, &map, 0x1000};
    unsigned int budget, draw;
    bool typec;
    /* Leave unrelated AICL/collapse protections and register bits intact. */
    map.regs[chip.base + USBIN_AICL_OPTIONS_CFG] = 0xdc;
    map.regs[chip.base + USBIN_LOAD_CFG] = 0xa5;
    map.regs[chip.base + USBIN_OPTIONS_1_CFG] = 0x18;
    assert(smb5_get_typec_limit(&chip, &budget, &typec) == 0);
    assert(budget == expected && typec == controlled);
    assert(smb5_apply_input_limit(&chip, budget, typec) == 0);
    draw = map.regs[chip.base + USBIN_CURRENT_LIMIT_CFG] * CURRENT_SCALE_FACTOR;
    assert(draw <= budget && budget - draw < CURRENT_SCALE_FACTOR);
    assert(!!(map.regs[chip.base + USBIN_CMD_IL] & USBIN_SUSPEND_BIT) ==
           (budget < CURRENT_SCALE_FACTOR));
    assert(!!(map.regs[chip.base + USBIN_LOAD_CFG] & ICL_OVERRIDE_AFTER_APSD_BIT) == typec);
    assert(!!(map.regs[chip.base + USBIN_OPTIONS_1_CFG] & BC1P2_SRC_DETECT_BIT) == !typec);
    assert(!(map.regs[chip.base + USBIN_OPTIONS_1_CFG] & HVDCP_EN_BIT));
    assert(!(map.regs[chip.base + CMD_ICL_OVERRIDE] & ICL_OVERRIDE_BIT));
    assert(!(map.regs[chip.base + USBIN_ICL_OPTIONS] & CFG_USB3P0_SEL_BIT));
    assert(!!(map.regs[chip.base + USBIN_ICL_OPTIONS] & USB51_MODE_BIT) == !typec);
    assert(map.regs[chip.base + USBIN_AICL_OPTIONS_CFG] == 0xdc);
    assert((map.regs[chip.base + USBIN_LOAD_CFG] & ~ICL_OVERRIDE_AFTER_APSD_BIT) == 0xa5);
    cases++;
}
int main(void)
{
    /* Observed adapter contracts, plus standby and Type-C Rp allowances. */
    exercise(1, POWER_SUPPLY_USB_TYPE_PD, 500000, 500000, true);
    exercise(1, POWER_SUPPLY_USB_TYPE_PD, 2210000, 2210000, true);
    exercise(1, POWER_SUPPLY_USB_TYPE_PD, 277000, 277000, true);
    exercise(1, POWER_SUPPLY_USB_TYPE_PD_PPS, 2000000, 2000000, true);
    exercise(1, POWER_SUPPLY_USB_TYPE_C, 1500000, 1500000, true);
    exercise(1, POWER_SUPPLY_USB_TYPE_C, 3000000, 3000000, true);
    exercise(1, POWER_SUPPLY_USB_TYPE_C, 500000, 500000, false);
    exercise(1, POWER_SUPPLY_USB_TYPE_C, 0, 0, true);
    exercise(1, POWER_SUPPLY_USB_TYPE_PD, -1, 0, true);
    exercise(1, POWER_SUPPLY_USB_TYPE_PD, 5000000, CURRENT_MAX_UA, true);
    /* Offline during detach/source role must discard the previous contract. */
    exercise(0, POWER_SUPPLY_USB_TYPE_PD, 2210000, 0, true);
    /* Every sub-step/rounding boundary stays within its permitted budget. */
    for (int ua = 0; ua <= CURRENT_MAX_UA; ua += 997)
        exercise(1, POWER_SUPPLY_USB_TYPE_PD, ua, ua, true);
    struct power_supply psy = {1, POWER_SUPPLY_USB_TYPE_PD, 2210000, -1, NULL};
    struct regmap map = {0};
    struct smb5_chip chip = {&psy, &map, 0x1000};
    unsigned int budget;
    bool typec;
    for (int prop = POWER_SUPPLY_PROP_ONLINE; prop <= POWER_SUPPLY_PROP_CURRENT_NOW; prop++) {
        psy.fail_property = prop;
        assert(smb5_get_typec_limit(&chip, &budget, &typec) == -EIO);
        cases++;
    }
    /* A failed register write must be surfaced, not reported as success. */
    for (int write = 1; write <= 6; write++) {
        memset(&map, 0, sizeof(map));
        map.fail_write = write;
        assert(smb5_apply_input_limit(&chip, 2210000, true) == -EIO);
        cases++;
    }
    /* A sysfs write cannot exceed the live contract; the charge limiter's
     * charging_enabled switch must leave the negotiated input path intact. */
    psy.fail_property = -1;
    struct power_supply charger = {.data = &chip};
    union power_supply_propval value = {.intval = 3000000};
    memset(&map, 0, sizeof(map));
    assert(smb5_set_property(&charger, POWER_SUPPLY_PROP_CURRENT_MAX, &value) == -EINVAL);
    assert(map.writes == 0);
    value.intval = -1;
    assert(smb5_set_property(&charger, POWER_SUPPLY_PROP_CURRENT_MAX, &value) == -EINVAL);
    assert(map.writes == 0);
    value.intval = 2210000;
    assert(smb5_set_property(&charger, POWER_SUPPLY_PROP_CURRENT_MAX, &value) == 0);
    assert(map.regs[chip.base + USBIN_CURRENT_LIMIT_CFG] == 44);
    value.intval = 0;
    assert(smb5_set_property(&charger, POWER_SUPPLY_PROP_CHARGING_ENABLED, &value) == 0);
    assert(!(map.regs[chip.base + CHARGING_ENABLE_CMD] & CHARGING_ENABLE_CMD_BIT));
    assert(map.regs[chip.base + USBIN_LOAD_CFG] & ICL_OVERRIDE_AFTER_APSD_BIT);
    assert(!(map.regs[chip.base + USBIN_CMD_IL] & USBIN_SUSPEND_BIT));
    /* Reduced contract and offline role are enforced on later sysfs writes. */
    psy.budget = 500000;
    value.intval = 2210000;
    assert(smb5_set_property(&charger, POWER_SUPPLY_PROP_CURRENT_MAX, &value) == -EINVAL);
    value.intval = 500000;
    assert(smb5_set_property(&charger, POWER_SUPPLY_PROP_CURRENT_MAX, &value) == 0);
    psy.online = 0;
    assert(smb5_set_property(&charger, POWER_SUPPLY_PROP_CURRENT_MAX, &value) == -EINVAL);
    value.intval = 0;
    assert(smb5_set_property(&charger, POWER_SUPPLY_PROP_CURRENT_MAX, &value) == 0);
    assert(map.regs[chip.base + USBIN_CMD_IL] & USBIN_SUSPEND_BIT);
    cases += 8;
    puts("TCPM budget, PMIC mode, disconnect, rounding and error cases passed.");
    printf("%u cases\n", cases);
    return 0;
}
'''

with tempfile.TemporaryDirectory(prefix="apollo-pd-policy-") as directory:
    src = Path(directory) / "policy.c"
    binary = Path(directory) / "policy"
    src.write_text(shim + usb_enum + "\n" + defines + "\n" + functions + tests)
    subprocess.run([os.environ.get("HOSTCC", "cc"), "-std=c11", "-Wall", "-Wextra",
                    "-Werror", str(src), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
