#!/usr/bin/env python3
"""Generate Sources/RouterCore/Resources/TimeZones.json from Asuswrt-Merlin 3006.102.5 (tag, not main).

Inputs, all from https://github.com/RMerl/asuswrt-merlin.ng/tree/3006.102.5/release/src/router:
  www/Advanced_System_Content.asp  the page's `var timezones` list: zone value and label template, in page order
  www/CN.dict                      the <#TZnn#> label text the router shows in Simplified Chinese
  www/ajax/tz_db.json              the daylight saving rule select_time_zone() fills in when a zone is chosen
  rc/common.c                      tz_list: the zoneinfo file HND routers link /etc/localtime to

Optionally --live <page> compares the result with Advanced_System_Content.asp as read from the router, whose labels
are already resolved. Only the zone list is used from it. Running this again with the same inputs gives the same file.
"""
import argparse, json, re, sys
from pathlib import Path

PAGE_LIST = re.compile(r'var timezones = \[(.*?)\]\];', re.S)
ENTRY = re.compile(r'\[\s*"([^"]+)"\s*,\s*"([^"]*)"\s*\]')


def page_zones(text):
    """(value, label) pairs of `var timezones`, without the "select" placeholder; // comments are dropped."""
    body = PAGE_LIST.search(text)
    if not body:
        raise SystemExit('timezones list not found')
    lines = [line.split('//', 1)[0] for line in (body.group(1) + ']').splitlines()]
    return [(value, label) for value, label in ENTRY.findall('\n'.join(lines)) if value != 'select']


def dictionary(text):
    return dict(line.split('=', 1) for line in text.splitlines() if '=' in line and not line.startswith('#'))


def zoneinfo(text):
    body = re.search(r'const zoneinfo_t tz_list\[\] = \{(.*?)\{ NULL \}', text, re.S)
    if not body:
        raise SystemExit('tz_list not found')
    return dict(re.findall(r'\{\s*"([^"]+)"\s*,\s*"([^"]+)"\s*\}', body.group(1)))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--page', required=True, type=Path)
    parser.add_argument('--dict', required=True, type=Path)
    parser.add_argument('--tz-db', required=True, type=Path)
    parser.add_argument('--rc-common', required=True, type=Path)
    parser.add_argument('--live', type=Path)
    parser.add_argument('--out', type=Path, default=Path(__file__).resolve().parents[1] / 'Sources/RouterCore/Resources/TimeZones.json')
    args = parser.parse_args()

    words = dictionary(args.dict.read_text())
    rules = json.loads(args.tz_db.read_text())
    links = zoneinfo(args.rc_common.read_text())
    zones = []
    for value, template in page_zones(args.page.read_text()):
        label = re.sub(r'<#(\w+)#>', lambda m: words[m.group(1)], template)
        # select_time_zone(): a value containing DST or TDT is a daylight saving zone.
        dst = 'DST' in value or 'TDT' in value
        zone = dict(value=value, label=label, dst=dst)
        # tz_db.json has "" for some daylight saving zones (UTC6DST in this firmware); the page then fills in
        # M3.2.0/2,M11.1.0/2, which RouterTimeZones applies the same way, so the file keeps tz_db.json as it is.
        if dst and rules.get(value):
            zone['rule'] = rules[value]
        if value in links:
            zone['iana'] = links[value]
        zones.append(zone)

    values = [zone['value'] for zone in zones]
    if len(set(values)) != len(values):
        raise SystemExit('duplicate zone values')
    if args.live:
        live = page_zones(args.live.read_text())
        if live != [(zone['value'], zone['label']) for zone in zones]:
            mismatched = [pair for pair in zip(live, [(z['value'], z['label']) for z in zones]) if pair[0] != pair[1]]
            raise SystemExit(f'router page differs from the tag: {len(live)} vs {len(zones)} zones, first differences {mismatched[:3]}')
    missing = [value for value in values if value not in links]
    fallback = [zone['value'] for zone in zones if zone['dst'] and 'rule' not in zone]
    unused = sorted(set(rules) - set(values) - {'ts'})
    args.out.write_text(json.dumps(dict(
        source='Asuswrt-Merlin 3006.102.5: www/Advanced_System_Content.asp timezones, www/CN.dict, www/ajax/tz_db.json, rc/common.c tz_list',
        zones=zones), ensure_ascii=False, indent=2) + '\n')
    print(f'{len(zones)} zones, {sum(z["dst"] for z in zones)} with daylight saving; page fallback rule: {fallback or "none"}; '
          f'no zoneinfo link: {missing or "none"}; tz_db.json entries not in the list: {unused or "none"}'
          + ('; matches the router page' if args.live else ''))


if __name__ == '__main__':
    sys.exit(main())
