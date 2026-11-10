"""
生成 RtlSdrScanner.res (VERSIONINFO 版本信息 / 作者信息)。

Delphi 自带的 brcc32 在写 VERSIONINFO 时:
  1) wValueLength 会漏掉字符串结尾的 \\0, 导致属性页字符串串到下一个字段;
  2) 无法正确把 GBK 中文转成 Unicode。
因此这里直接按 VS_VERSIONINFO 结构生成 RES 文件。

用法: python tools\\mkver.py
"""
import os
import struct

OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   'RtlSdrScanner.res')


def pad4(b):
    return b + b'\x00' * ((-len(b)) % 4)


def wkey(s):
    return s.encode('utf-16-le') + b'\x00\x00'


def block(key, value, val_len, val_type, children=b''):
    head = wkey(key)
    head = head + b'\x00' * ((-(6 + len(head))) % 4)
    body = head + pad4(value) + pad4(children)
    return struct.pack('<HHH', 6 + len(body), val_len, val_type) + body


def str_block(key, text):
    return block(key, wkey(text), len(text) + 1, 1)


FIXED = struct.pack('<13I',
    0xFEEF04BD, 0x00010000,          # signature, struct version
    0x00020000, 0x00000000,          # file version 2.0.0.0
    0x00020000, 0x00000000,          # product version 2.0.0.0
    0x0000003F, 0x00000000,          # flags mask, flags
    0x00040004, 0x00000001,          # OS = VOS_NT_WINDOWS32, type = VFT_APP
    0x00000000, 0x00000000, 0x00000000)

STRINGS = [
    ('CompanyName', '老皮'),
    ('FileDescription', 'RTLSDR Scanner - Delphi 12 移植版'),
    ('FileVersion', '2.0.0.0'),
    ('InternalName', 'RtlSdrScanner'),
    ('LegalCopyright', 'Copyright (C) 2026 老皮'),
    ('OriginalFilename', 'RtlSdrScanner.exe'),
    ('ProductName', 'RTLSDR Scanner'),
    ('ProductVersion', '2.0.0.0'),
    ('Comments', 'QQ: 30922884  www.2pascal.com  github.com/shirong21cn'),
]

string_table = block('080404B0', b'', 0, 1,
                     b''.join(str_block(k, v) for k, v in STRINGS))
string_file_info = block('StringFileInfo', b'', 0, 1, string_table)

translation = block('Translation', struct.pack('<HH', 0x0804, 0x04B0), 4, 0)
var_file_info = block('VarFileInfo', b'', 0, 1, translation)

version_info = block('VS_VERSION_INFO', FIXED, len(FIXED), 0,
                     string_file_info + var_file_info)

# RES 文件: 32 字节文件头 + 32 字节资源头 + 数据
header = struct.pack('<IIHHHHIHHII', 0, 32, 0xFFFF, 0, 0xFFFF, 0, 0, 0, 0, 0, 0)
entry = struct.pack('<IIHHHHIHHII',
                    len(version_info), 32, 0xFFFF, 16, 0xFFFF, 1,
                    0, 0, 0x0804, 0, 0)

with open(OUT, 'wb') as f:
    f.write(header + entry + version_info)

print('written', OUT, len(header) + len(entry) + len(version_info), 'bytes')
