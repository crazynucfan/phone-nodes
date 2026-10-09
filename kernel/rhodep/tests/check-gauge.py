#!/usr/bin/env python3
"""Compile actual CW2217 routines with a fake register transport and test units/errors.
Usage: python3 check-gauge.py /path/to/patched/linux
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

tree = Path(sys.argv[1])
driver = (tree / 'drivers/power/supply/cw2217_battery.c').read_text()
header = (tree / 'include/linux/power_supply.h').read_text()

def function(name):
    match = re.search(r'^static [^\n]*\b' + name + r'\(', driver, re.M)
    if not match:
        raise RuntimeError('Missing ' + name)
    end = driver.index('\n}\n', match.start()) + 3
    return driver[match.start():end]

defines = '\n'.join(line for line in driver.splitlines() if line.startswith('#define '))
enums = '\n'.join(re.search(r'enum ' + name + r' \{.*?\n};', header, re.S).group()
                  for name in ['power_supply_property'])
funcs = '\n'.join(function(n) for n in ['cw2217_read_word', 'cw2217_check_ready',
    'cw2217_voltage_uv', 'cw2217_capacity', 'cw2217_current_ua', 'cw2217_get_property',
    'cw2217_writeable_reg'])
# The transport has no write API. Any future hardware-write path fails compilation.
assert not re.search(r'\b(?:regmap_(?:write|bulk_write|update_bits)|i2c_smbus_write\w*)\s*\(', driver)
shim = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef int16_t s16;
typedef int64_t s64;
#define BIT(n) (1U << (n))
#define GENMASK(h,l) (((~0U) << (l)) & ((~0U) >> (31-(h))))
#define min_t(t,a,b) ((t)(a) < (t)(b) ? (t)(a) : (t)(b))
#define min(a,b) ((a) < (b) ? (a) : (b))
#define div_s64(a,b) ((a) / (b))
#define POWER_SUPPLY_STATUS_CHARGING 1
#define POWER_SUPPLY_STATUS_DISCHARGING 2
#define POWER_SUPPLY_STATUS_NOT_CHARGING 3
struct regmap { unsigned int regs[256]; int calls, fail_at, rollover, always_roll; };
struct cw2217 { struct regmap *regmap; u32 shunt_uohms; };
struct power_supply { struct cw2217 *data; };
struct device { int unused; };
union power_supply_propval { int intval; const char *strval; };
static void *power_supply_get_drvdata(struct power_supply *psy) { return psy->data; }
static int regmap_read(struct regmap *map, unsigned int reg, unsigned int *value)
{
    if (++map->calls == map->fail_at) return -EIO;
    *value = map->regs[reg];
    return 0;
}
static int regmap_bulk_read(struct regmap *map, unsigned int reg, void *buffer, size_t count)
{
    u8 *bytes = buffer;
    if (++map->calls == map->fail_at) return -EREMOTEIO;
    assert(count == 2 && reg < 255);
    bytes[0] = map->regs[reg]; bytes[1] = map->regs[reg+1];
    if (map->rollover || map->always_roll) { ++map->regs[reg]; map->rollover = 0; }
    return 0;
}
'''
tests = r'''
static unsigned int checks;
#define CHECK(v) do { assert(v); ++checks; } while (0)
static void word(struct regmap *map, unsigned int reg, u16 value)
{ map->regs[reg] = value >> 8; map->regs[reg+1] = value & 255; }
static void ready(struct regmap *map)
{
    memset(map, 0, sizeof(*map));
    map->regs[CW2217_MODE] = 0;
    map->regs[CW2217_SOC_ALERT] = 0x80;
    map->regs[CW2217_STATE] = 0x0c;
    map->regs[CW2217_FW_VERSION] = 0x44;
}
int main(void)
{
    struct regmap map;
    struct cw2217 cw = { &map, 5000 };
    struct power_supply psy = { &cw };
    union power_supply_propval val;
    u16 value;
    ready(&map);
    CHECK(cw2217_check_ready(&cw) == 0);
    map.regs[CW2217_MODE] = 0xf0; CHECK(cw2217_check_ready(&cw) == -EAGAIN);
    ready(&map); map.regs[CW2217_SOC_ALERT] = 0; CHECK(cw2217_check_ready(&cw) == -EAGAIN);
    ready(&map); map.regs[CW2217_STATE] = 0x04; CHECK(cw2217_check_ready(&cw) == -EAGAIN);
    ready(&map); map.regs[CW2217_FW_VERSION] = 0x84; CHECK(cw2217_check_ready(&cw) == -ENODEV);
    map.regs[CW2217_FW_VERSION] = 0x04; CHECK(cw2217_check_ready(&cw) == -ENODEV);
    for (int i=1; i<=4; ++i) { ready(&map); map.fail_at=i; CHECK(cw2217_check_ready(&cw) == -EIO); }
    CHECK(cw2217_voltage_uv(0x3357) == 4107187);
    CHECK(cw2217_voltage_uv(0x3333) == 4095937);
    CHECK(cw2217_voltage_uv(0) == 0);
    CHECK(cw2217_voltage_uv(0x3fff) == 5119687);
    CHECK(cw2217_capacity(0x4ca1) == 76);
    CHECK(cw2217_capacity(0x6400) == 100);
    CHECK(cw2217_capacity(0xffff) == 100);
    CHECK(cw2217_capacity(0x00ff) == 0);
    CHECK(cw2217_current_ua(&cw, 0) == 0);
    CHECK(cw2217_current_ua(&cw, 3125) == 1000000);
    CHECK(cw2217_current_ua(&cw, (u16)-3125) == -1000000);
    CHECK(cw2217_current_ua(&cw, 0x7fff) == 10485440);
    CHECK(cw2217_current_ua(&cw, 0x8000) == -10485760);
    cw.shunt_uohms=10000; CHECK(cw2217_current_ua(&cw, 6250) == 1000000); cw.shunt_uohms=5000;
    ready(&map); word(&map,CW2217_SOC,0x4ca1);
    CHECK(cw2217_read_word(&cw,CW2217_SOC,&value) == 0 && value == 0x4ca1);
    map.calls=0; map.rollover=1;
    CHECK(cw2217_read_word(&cw,CW2217_SOC,&value) == 0 && value == 0x4da1 && map.calls == 4);
    map.calls=0; map.always_roll=1;
    CHECK(cw2217_read_word(&cw,CW2217_SOC,&value) == -EAGAIN && map.calls == 6);
    for (int i=1; i<=2; ++i) { ready(&map); map.fail_at=i;
        CHECK(cw2217_read_word(&cw,CW2217_SOC,&value) == (i==1 ? -EREMOTEIO : -EIO)); }
    ready(&map); word(&map,CW2217_SOC,0x4ca1); word(&map,CW2217_VOLTAGE,0x3357);
    word(&map,CW2217_CYCLES,0x1553); map.regs[CW2217_TEMP]=157; map.regs[CW2217_SOH]=100;
    CHECK(cw2217_get_property(&psy,POWER_SUPPLY_PROP_CAPACITY,&val) == 0 && val.intval == 76);
    CHECK(cw2217_get_property(&psy,POWER_SUPPLY_PROP_VOLTAGE_NOW,&val) == 0 && val.intval == 4107187);
    CHECK(cw2217_get_property(&psy,POWER_SUPPLY_PROP_TEMP,&val) == 0 && val.intval == 385);
    CHECK(cw2217_get_property(&psy,POWER_SUPPLY_PROP_CYCLE_COUNT,&val) == 0 && val.intval == 341);
    CHECK(cw2217_get_property(&psy,POWER_SUPPLY_PROP_STATE_OF_HEALTH,&val) == 0 && val.intval == 100);
    map.regs[CW2217_SOH]=255;
    CHECK(cw2217_get_property(&psy,POWER_SUPPLY_PROP_STATE_OF_HEALTH,&val) == 0 && val.intval == 100);
    CHECK(cw2217_get_property(&psy,POWER_SUPPLY_PROP_PRESENT,&val) == 0 && val.intval == 1);
    CHECK(cw2217_get_property(&psy,POWER_SUPPLY_PROP_MODEL_NAME,&val) == 0 && !strcmp(val.strval,"CW2217"));
    CHECK(cw2217_get_property(&psy,POWER_SUPPLY_PROP_MANUFACTURER,&val) == 0 && !strcmp(val.strval,"CellWise"));
    for (int i=0; i<65536; ++i) {
        word(&map,CW2217_CURRENT,(u16)i);
        CHECK(cw2217_get_property(&psy,POWER_SUPPLY_PROP_CURRENT_NOW,&val) == 0 &&
              val.intval == (int)((int64_t)(int16_t)i*320));
        CHECK(cw2217_get_property(&psy,POWER_SUPPLY_PROP_STATUS,&val) == 0 &&
              val.intval == (i==0 ? POWER_SUPPLY_STATUS_NOT_CHARGING :
                ((int16_t)i>0 ? POWER_SUPPLY_STATUS_CHARGING : POWER_SUPPLY_STATUS_DISCHARGING)));
    }
    for (int i=0; i<256; ++i) {
        map.regs[CW2217_TEMP]=i;
        CHECK(cw2217_get_property(&psy,POWER_SUPPLY_PROP_TEMP,&val) == 0 && val.intval == i*5-400);
        CHECK(!cw2217_writeable_reg(NULL,i));
    }
    for (int i=1; i<=6; ++i) {
        ready(&map); map.fail_at=i; val.intval=123;
        CHECK(cw2217_get_property(&psy,POWER_SUPPLY_PROP_CAPACITY,&val) < 0 && val.intval == 123);
    }
    ready(&map); map.regs[CW2217_STATE]=0;
    CHECK(cw2217_get_property(&psy,POWER_SUPPLY_PROP_CAPACITY,&val) == -EAGAIN);
    puts("CW2217 units, signed current, rollover, ready state, transport errors and read-only checks passed.");
    printf("%u checks\n",checks);
}
'''
with tempfile.TemporaryDirectory() as td:
    source = Path(td) / 'check.c'; binary = Path(td) / 'check'
    source.write_text(shim + enums + '\n' + defines + '\n' + funcs + tests)
    subprocess.run(['cc','-std=c11','-Wall','-Wextra','-Werror','-Wno-unused-parameter',str(source),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
