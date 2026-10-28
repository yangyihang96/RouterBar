#!/usr/bin/env python3
"""Builds Sources/RouterCore/Resources/PolicyTexts.json: the documents js/asus_policy.js (Asuswrt-Merlin tag 3006.102.5)
shows in its policy windows, composed from the router's CN.dict the way the script composes them.

Usage: script/generate_policy_texts.py <CN.dict> [output]

Each document is a list of blocks in page order. A block's "html" is what the page writes for it (dictionary text with
the script's own replacements); the app shows it through HTMLText. "marker" is the list number CSS draws in front of an
item, "depth" its nesting, "bold" the font weight the page's style rules give it. "links" lists the targets the block's
links open: an address, "policy" (the ASUS privacy policy page in the router's language, which the script links as
forward.html?type=Policy&lang=<preferred_lang>) or "personal" (the personal data window, showPersonalData).
"""
import json
import re
import sys

dictionary = {}
with open(sys.argv[1], encoding='utf-8') as source:
    for line in source:
        line = line.rstrip('\r\n')
        if '=' in line:
            key, value = line.split('=', 1)
            # httpd's dictionary lookup takes the first line that starts with "<key>=".
            dictionary.setdefault(key, value)

def d(key):
    value = dictionary[key]
    # The texts sit inside JavaScript template literals; none of these uses an escape, a backtick or "${".
    assert '\\' not in value and '`' not in value and '${' not in value, key
    return value

AA = re.compile(r'\[aa\](.*?)\[/aa\]')
ANCHOR = re.compile(r'<a\b[^>]*\bhref="([^"]*)"[^>]*>(.*?)</a>', re.S)

def block(kind, html, marker='', depth=0, bold=False, aa='policy'):
    links = []
    for match in ANCHOR.finditer(html):
        links.append({'title': re.sub(r'<[^>]*>', '', match.group(2)).strip(), 'url': match.group(1)})
    # PolicyModalComponent and PersonalDataModalComponent turn every remaining [aa]…[/aa] into a link to the policy page.
    for match in AA.finditer(html):
        links.append({'title': match.group(1).strip(), 'url': aa})
    html = AA.sub(lambda m: '<a>' + m.group(1) + '</a>', html)
    return {'kind': kind, 'html': html, 'marker': marker, 'depth': depth, 'bold': bold, 'links': links}

def pp(version):
    """Content.PP.HTMLv2 (22–46) and HTMLv4 (47–71)."""
    desc2 = d('ASUS_PP_Desc_2').replace('%1$@', d('menu5_6')).replace('%2$@', d('menu_privacy'))
    # `.replace(/\[aa\](.*?)\[\/aa\]/g, '<span class="link" onclick="showPersonalData(N)">$1</span>')`
    personal = [{'title': m.group(1).strip(), 'url': 'personal'} for m in AA.finditer(desc2)]
    desc2 = AA.sub(lambda m: '<span>' + m.group(1) + '</span>', desc2)
    second = block('text', desc2)
    second['links'] = personal + second['links']
    return [
        block('title', d('ASUS_PP_Title') + '</u></b>', bold=True),
        block('text', d('ASUS_PP_Desc_v%d' % version)),
        second,
        block('text', d('ASUS_PP_Desc_3')),
        block('text', d('ASUS_PP_Desc_4')),
        block('text', d('ASUS_PP_Desc_5')),
    ]

def personal2():
    """Content.PP.PersonalDataHTMLv2 (73–130). Nested markers are `'(' counter(list-item) ') '`."""
    law1 = d('ASUS_PP_Law_1').replace('[bu]', '<b><u>').replace('[/bu]', '</b></u>').replace('%@', d('CTL_Agree'))
    law3 = d('ASUS_PP_Law_3').replace('%@', d('CTL_Decline'))
    return [
        block('item', law1, '1.'),
        block('item', d('ASUS_PP_Law_1_1'), '(1)', 1),
        block('item', d('ASUS_PP_Law_1_2') + d('ASUS_PP_Law_1_3'), '(2)', 1),
        block('item', d('ASUS_PP_Law_2'), '2.'),
        block('item', d('ASUS_PP_Law_2_1'), '(1)', 1),
        block('item', d('ASUS_PP_Law_2_2'), '(2)', 1),
        block('item', d('ASUS_PP_Law_2_3'), '(3)', 1),
        block('item', law3, '3.'),
        block('item', d('ASUS_PP_Law_3_1') + d('ASUS_PP_Law_3_2'), '(1)', 1),
        block('item', d('ASUS_PP_Law_3_3'), '(2)', 1),
        block('item', d('ASUS_PP_Law_4'), '4.'),
        block('end', d('ASUS_PP_End')),
    ]

def personal4():
    """Content.PP.PersonalDataHTMLv4 (131–176)."""
    url = 'https://www.asus.com/support/faq/1053743/'
    law13 = d('ASUS_Personal_Law_1_3').replace('[' + url + ']', '[<a target="_blank" href="' + url + '">' + url + '</a>]', 1)
    return [
        block('text', d('ASUS_Personal_Desc')),
        block('item', d('ASUS_Personal_Law_1_1'), '1.'),
        block('item', d('ASUS_Personal_Law_1_2'), '', 0),
        block('item', law13, '', 0),
        block('item', d('ASUS_Personal_Law_2'), '2.'),
        block('item', d('ASUS_Personal_Law_2_1_1') + d('ASUS_Personal_Law_2_1_2'), '(1)', 1),
        block('item', d('ASUS_Personal_Law_2_2'), '(2)', 1),
        block('item', d('ASUS_Personal_Law_3'), '3.'),
        block('item', d('ASUS_Personal_Law_4'), '4.'),
        block('item', d('ASUS_Personal_Law_5'), '5.'),
    ]

def eula():
    """Content.EULA.HTML (181–317). Nested markers are `counters(list-item,".",list-item)" "` (1.1, 1.1.1); the first
    item is bold (`.policy_law > ol > li:first-child`), items inside items are normal, <b> stays bold."""
    blocks = [block('title', d('ASUS_EULA_Title_B') + '</u></b>', bold=True), block('text', d('ASUS_EULA_Desc'))]
    def item(key, marker, depth, bold=False):
        blocks.append(block('item', d(key), marker, depth, bold))
    def desc(key, depth):
        blocks.append(block('item', d(key), '', depth))
    item('ASUS_EULA_Law_1', '1.', 0, True)
    for n, subs in ((1, 2), (2, 2), (3, 3)):
        item('ASUS_EULA_Law_1_%d' % n, '1.%d' % n, 1, True)
        for s in range(1, subs + 1):
            item('ASUS_EULA_Law_1_%d_%d' % (n, s), '1.%d.%d' % (n, s), 2)
    item('ASUS_EULA_Law_1_4', '1.4', 1, True)
    desc('ASUS_EULA_Law_1_4_Desc', 1)
    item('ASUS_EULA_Law_2', '2.', 0)
    for n in (1, 2):
        item('ASUS_EULA_Law_2_%d' % n, '2.%d' % n, 1, True)
        for s in (1, 2):
            item('ASUS_EULA_Law_2_%d_%d' % (n, s), '2.%d.%d' % (n, s), 2)
    for n in (3, 4, 5):
        item('ASUS_EULA_Law_%d' % n, '%d.' % n, 0)
        desc('ASUS_EULA_Law_%d_Desc' % n, 0)
    item('ASUS_EULA_Law_6', '6.', 0)
    item('ASUS_EULA_Law_6_1', '6.1', 1)
    item('ASUS_EULA_Law_6_2', '6.2', 1)
    item('ASUS_EULA_Law_7', '7.', 0)
    desc('ASUS_EULA_Law_7_Desc', 0)
    item('ASUS_EULA_Law_8', '8.', 0)
    item('ASUS_EULA_Law_8_1', '8.1', 1, True)
    item('ASUS_EULA_Law_8_1_1', '8.1.1', 2)
    item('ASUS_EULA_Law_8_1_2', '8.1.2', 2)
    item('ASUS_EULA_Law_8_2', '8.2', 1, True)
    desc('ASUS_EULA_Law_8_2_Desc', 1)
    item('ASUS_EULA_Law_8_3', '8.3', 1)
    for n in range(9, 13):
        item('ASUS_EULA_Law_%d' % n, '%d.' % n, 0)
        desc('ASUS_EULA_Law_%d_Desc' % n, 0)
    return blocks

def tm():
    """Content.TM.HTML (319–328). The window gives the links their addresses by id (1098–1100): eula_url the Trend Micro
    EULA in the router's language ("tmeula"), tm_eula_url and tm_disclosure_url the ASUS-hosted policies."""
    targets = {'eula_url': 'tmeula', 'tm_eula_url': 'https://nw-dlcdnet.asus.com/trend/tm_privacy',
               'tm_disclosure_url': 'https://nw-dlcdnet.asus.com/trend/tm_pdcd'}
    blocks = []
    for key in ('TM_eula_desc1', 'TM_eula_desc2', 'TM_privacy_policy', 'TM_data_collection', 'TM_eula_desc3'):
        html = d(key)
        item = block('text', html)
        for match in re.finditer(r'<a\b[^>]*\bid="([^"]+)"[^>]*>(.*?)</a>', html, re.S):
            item['links'].append({'title': re.sub(r'<[^>]*>', '', match.group(2)).strip(), 'url': targets[match.group(1)]})
        blocks.append(item)
    return blocks

texts = {
    'source': 'Asuswrt-Merlin 3006.102.5 www/js/asus_policy.js with www/CN.dict',
    'titles': {'PP': d('ASUS_PP_Title'), 'EULA': d('ASUS_EULA_Title'), 'personal': d('ASUS_Personal'), 'TM': d('lyra_TrendMicro_agreement')},
    'documents': {'PP2': pp(2), 'PP4': pp(4), 'personal2': personal2(), 'personal4': personal4(), 'EULA': eula(), 'TM': tm()},
}
output = sys.argv[2] if len(sys.argv) > 2 else 'Sources/RouterCore/Resources/PolicyTexts.json'
with open(output, 'w', encoding='utf-8') as target:
    json.dump(texts, target, ensure_ascii=False, indent=1, sort_keys=True)
    target.write('\n')
