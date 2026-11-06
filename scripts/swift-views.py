#!/usr/bin/env python3
# Reads how a Swift binary builds its SwiftUI views, such as a System Settings extension, so a control
# rebuilt in Safelight can use the same views, modifiers and constants instead of measurements.
#
#   scripts/swift-views.py <binary or bundle> types           its types (structs, classes, enums) and where
#                                                             their descriptors are
#   scripts/swift-views.py <binary or bundle> fields [name]   each type's stored properties, with their types
#   scripts/swift-views.py <binary or bundle> bodies [name]   each type's associated types, such as a view's
#                                                             Body, with every `some View` replaced by the
#                                                             type it really is
#   scripts/swift-views.py <binary or bundle> stubs [text]    the functions it calls in other libraries, by
#                                                             the address of the stub that calls each
#   scripts/swift-views.py <binary or bundle> callers <text>  where it calls those, each call with the lines
#                                                             before it, where its constants are loaded
#                                                             (`fmov d0, #0.5` before Animation.spring, say)
#   scripts/swift-views.py <binary or bundle> opaque <address>  the underlying types of the opaque type
#                                                             descriptor there
#
# [name] and <text> match part of a name, ignoring case. A universal binary is thinned to arm64e (or arm64)
# first; that, its fixups (dyld_info) and its disassembly (llvm-objdump) are kept in build/swift-views/.
# For example, System Settings › Wallpaper's lock screen preview:
#
#   scripts/swift-views.py /System/Library/ExtensionKit/Extensions/Wallpaper.appex bodies GroupItemDetail
#   scripts/swift-views.py /System/Library/ExtensionKit/Extensions/Wallpaper.appex callers Animation.spring
#
# Swift writes the types in these records as mangled names with symbolic references, four-byte offsets to a
# type's descriptor in the binary or to a GOT slot that dyld binds to one elsewhere. swift-demangle can't
# take those, so this has its own demangler for the part of the mangling SwiftUI bodies use. Packs show as
# Pack{…}, optionals (an `if` without an `else`) with ?, and opaque types as some{…} around their
# underlying type, or as some[the function] for one from another library, followed by its generic
# arguments. A body that differs by macOS version (`if #available`) shows as some{chosen by #available in
# the function at …}, the function that picks it at run time. It reads every type of all 288 extensions in
# /System/Library/ExtensionKit/Extensions on macOS 27.2 (2026-11-06). A computed property's getter often
# loads its storage through a field offset global, which `otool -ov <thinned binary>` names in the
# class's ivar list.
import os
import re
import struct
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

if len(sys.argv) < 3 or sys.argv[2] not in ('types', 'fields', 'bodies', 'stubs', 'callers', 'opaque'):
    usage = open(__file__).read().split('\nimport ')[0].split('\n')[1:]
    sys.exit('\n'.join(line[2:] for line in usage))
target, mode = sys.argv[1], sys.argv[2]
pattern = sys.argv[3].lower() if len(sys.argv) > 3 else ''

# The executable, if given a bundle
if os.path.isdir(target):
    import plistlib
    try:
        name = plistlib.load(open(os.path.join(target, 'Contents', 'Info.plist'), 'rb')).get('CFBundleExecutable')
    except Exception:  # an Info.plist plistlib can't read: the executable is usually named as the bundle
        name = None
    bundle, target = target, os.path.join(target, 'Contents', 'MacOS', name or os.path.splitext(os.path.basename(target.rstrip('/')))[0])
    if not os.path.isfile(target):
        sys.exit('%s has no executable' % bundle)

# The binary thinned to one architecture, its fixups and its disassembly, kept until the binary changes
cache = os.path.join(ROOT, 'build', 'swift-views', re.sub(r'[^A-Za-z0-9]+', '-', os.path.abspath(target)).strip('-'))
os.makedirs(cache, exist_ok=True)
thin, fixups_path, disassembly_path = (os.path.join(cache, n) for n in ('binary', 'fixups.txt', 'disassembly.txt'))
if not os.path.exists(thin) or os.path.getmtime(thin) < os.path.getmtime(target):
    archs = subprocess.run(['lipo', '-archs', target], capture_output=True, text=True).stdout.split()
    arch = 'arm64e' if 'arm64e' in archs else 'arm64'
    if len(archs) > 1:
        subprocess.run(['lipo', '-thin', arch, target, '-output', thin], check=True)
    else:
        subprocess.run(['cp', target, thin], check=True)
    for stale in (fixups_path, disassembly_path):
        if os.path.exists(stale):
            os.remove(stale)
if not os.path.exists(fixups_path):
    with open(fixups_path, 'w') as f:
        subprocess.run(['dyld_info', '-fixups', thin], stdout=f, check=True)

data = open(thin, 'rb').read()

# Segments and sections
sections, segments = {}, []
count = struct.unpack_from('<I', data, 16)[0]
offset = 32
for _ in range(count):
    command, size = struct.unpack_from('<II', data, offset)
    if command == 0x19:  # LC_SEGMENT_64
        segment = data[offset + 8:offset + 24].rstrip(b'\0').decode()
        vmaddr, vmsize, fileoff, filesize = struct.unpack_from('<QQQQ', data, offset + 24)
        if filesize:  # not __PAGEZERO, which would cover every address from 0 at file offset 0
            segments.append((vmaddr, vmsize, fileoff))
        n = struct.unpack_from('<I', data, offset + 64)[0]
        s = offset + 72
        for _ in range(n):
            name = data[s:s + 16].rstrip(b'\0').decode()
            addr, ssize, soff = struct.unpack_from('<QQI', data, s + 32)
            sections[(segment, name)] = (addr, ssize, soff)
            s += 80
    offset += size


def file_offset(addr):
    for vmaddr, vmsize, fileoff in segments:
        if vmaddr <= addr < vmaddr + vmsize:
            return addr - vmaddr + fileoff
    raise ValueError(hex(addr))


def address(off):
    for vmaddr, vmsize, fileoff in segments:
        if fileoff <= off < fileoff + vmsize:
            return off - fileoff + vmaddr
    raise ValueError(hex(off))


def u32(a): return struct.unpack_from('<I', data, file_offset(a))[0]
def i32(a): return struct.unpack_from('<i', data, file_offset(a))[0]
def u16(a): return struct.unpack_from('<H', data, file_offset(a))[0]
def relative(a): return a + i32(a)


def cstring(a):
    o = file_offset(a)
    return data[o:data.index(b'\0', o)].decode('utf8', 'replace')


# What dyld binds each pointer to (a symbol), or rebases it to (an address in the binary)
binds, rebases = {}, {}
for line in open(fixups_path):
    m = re.match(r'\s+\S+\s+\S+\s+0x([0-9A-F]+)\s+(\S+)\s+(\S+)', line)
    if m:
        a, kind, value = int(m.group(1), 16), m.group(2), m.group(3)
        if 'bind' in kind:
            binds[a] = value.split('/', 1)[-1].lstrip('_')
        else:
            rebases[a] = int(value, 16)

_demangled = {}


def demangle_symbols(symbols):
    """swift-demangle --simplified, for symbols without symbolic references, all at once"""
    todo = [s for s in symbols if s not in _demangled]
    if todo:
        out = subprocess.run(['xcrun', 'swift-demangle', '--simplified'], input='\n'.join(todo), capture_output=True, text=True).stdout.split('\n')
        _demangled.update(zip(todo, out))
    return [_demangled[s] for s in symbols]


def context_name(a, depth=0):
    """A context descriptor's name, with those of the contexts it's in"""
    flags = u32(a)
    kind = flags & 0x1f
    p = i32(a + 4)
    parent = None
    if p:
        pa = a + 4 + (p & ~1)
        parent = rebases.get(pa) if p & 1 else pa
    prefix = context_name(parent, depth + 1) + '.' if parent and depth < 10 else ''
    if kind == 0:
        return cstring(relative(a + 8))
    if kind in (3, 16, 17, 18):  # protocol, class, struct, enum
        return prefix + cstring(relative(a + 8))
    if kind == 1:
        return 'extension(%s)' % prefix.rstrip('.')
    if kind == 2:
        return prefix + '<private>'
    if kind == 4:
        return 'opaque@%x' % a
    return 'context%d@%x' % (kind, a)


class Node:
    def __init__(self, kind, *args):
        self.kind, self.args = kind, list(args)


TYPES = ('type', 'nominal', 'generic', 'tuple', 'opaque', 'optional', 'param', 'assoc', 'function', 'metatype', 'pack',
         'existential', 'raw')
STANDARD = dict(a='Array', b='Bool', c='UnicodeScalar', D='Dictionary', d='Double', f='Float', h='Set', I='DefaultIndices',
                i='Int', J='Character', N='ClosedRange', n='Range', O='ObjectIdentifier', P='UnsafePointer',
                p='UnsafeMutablePointer', q='Optional', R='UnsafeBufferPointer', r='UnsafeMutableBufferPointer', S='String',
                s='Substring', u='UInt', V='UnsafeRawPointer', v='UnsafeMutableRawPointer', W='UnsafeRawBufferPointer',
                w='UnsafeMutableRawBufferPointer', z='RandomAccessCollection', T='Sequence', l='Collection',
                Z='SignedInteger', y='StringProtocol', j='Encodable', e='Decodable')
QUIET_MODULES = ('Swift', 'SwiftUI', 'SwiftUICore', '__C', 'Foundation', 'CoreFoundation', 'AppKit')


def opaque_underlying(a):
    """The underlying types an opaque type descriptor records, after its generic signature"""
    flags = u32(a)
    p = a + 8
    if flags & 0x80:  # generic: a header, the parameters (padded to 4 bytes) and the requirements
        parameters, requirements = struct.unpack_from('<HH', data, file_offset(p))
        p += 8 + ((parameters + 3) & ~3) + 12 * requirements
    return [mangled(relative(p + 4 * k)) for k in range(flags >> 16)]


def show(n, depth=0):
    if n is None:
        raise ValueError('a type missing')
    k, a = n.kind, n.args
    levels = lambda ls: ''.join('<' + ', '.join(show(x, depth) for x in level) + '>' for level in ls if level)
    if k in ('type', 'ident', 'module', 'raw'):
        return a[0]
    if k == 'nominal':
        context = show(a[0], depth)
        return a[1] if context in QUIET_MODULES else context + '.' + a[1]
    if k == 'generic':
        return show(a[0], depth) + levels(a[1])
    if k == 'tuple':
        return '(' + ', '.join(show(x, depth) for x in a[0]) + ')'
    if k == 'pack':
        return 'Pack{' + ', '.join(show(x, depth) for x in a[0]) + '}'
    if k == 'opaque':
        descriptor, index, args = a
        if descriptor.kind == 'opaque descriptor' and depth < 12:
            underlying = opaque_underlying(descriptor.args[0])
            inner = show(underlying[index], depth + 1) if index < len(underlying) else '?'
            return 'some{%s}%s' % (inner, levels(args))
        if descriptor.kind == 'external opaque':
            return 'some[%s]%s' % (descriptor.args[0], levels(args))
        return 'some#%d%s' % (index, levels(args))
    if k == 'optional':
        return ('(%s)?' if a[0].kind in ('function', 'existential') else '%s?') % show(a[0], depth)
    if k == 'param':
        return 'τ_%d_%d' % (a[0], a[1])
    if k == 'assoc':
        return show(a[0], depth) + '.' + a[1]
    if k == 'function':
        parameters = show(a[0], depth)
        return (parameters if a[0].kind == 'tuple' else '(' + parameters + ')') + ' -> ' + show(a[1], depth)
    if k == 'existential':
        return ' & '.join(show(x, depth) for x in a[0]) or 'Any'
    if k == 'metatype':
        return show(a[0], depth) + '.Type'
    return '%s%r' % (k, a)


def resolve(kind, at, offset):
    """What a symbolic reference refers to: a descriptor in the binary (1), one through a GOT slot (2), or
    an @objc protocol (0x0c)"""
    target = address(at) + offset
    if kind == 2:
        if target in rebases:
            target = rebases[target]
        elif target in binds:
            symbol = binds[target]
            if symbol.startswith('$s') and symbol.endswith('MQ'):  # another library's opaque type
                name = demangle_symbols([symbol])[0]
                m = re.search(r'<<opaque return type of (.*)>>', name)
                return Node('external opaque', m.group(1) if m else name)
            if symbol.startswith('$s'):
                body = symbol[2:]
                for suffix, kept in (('Mn', ''), ('Mp', 'P'), ('MQ', ''), ('N', '')):
                    if body.endswith(suffix):
                        body = body[:-len(suffix)] + kept
                        break
                try:
                    return demangle(list(body))
                except Exception:
                    return Node('type', demangle_symbols([symbol])[0])
            return Node('type', symbol)
        else:
            return Node('type', 'got@%x' % target)
    if kind == 0x0c:  # an @objc protocol: a reference to its protocol_t, whose name is after its isa
        protocol = target + i32(target)
        protocol = rebases.get(protocol, protocol)
        name = rebases.get(protocol + 8)
        return Node('type', demangle_symbols([cstring(name)])[0] if name else 'objc protocol@%x' % protocol)
    if kind in (1, 2):
        if u32(target) & 0x1f == 4:
            return Node('opaque descriptor', target)
        return Node('type', context_name(target))
    return Node('type', 'reference%d' % kind)


def demangle(tokens):
    """Swift's demangler (Demangler.cpp) for type names: a stack of nodes, and the substitutions they add"""
    stack, substitutions, words = [], [], []
    i = 0

    def peek():
        return tokens[i] if i < len(tokens) else None

    def natural():
        nonlocal i
        s = ''
        while isinstance(peek(), str) and peek().isdigit():
            s += tokens[i]
            i += 1
        return int(s) if s else None

    def index():
        nonlocal i
        if peek() == '_':
            i += 1
            return 0
        n = natural()
        assert peek() == '_', 'index'
        i += 1
        return n + 1

    def pop(*kinds):
        return stack.pop() if stack and stack[-1].kind in kinds else None

    def pop_type():
        return pop(*TYPES)

    def pop_list():
        """A tuple's or pack's elements, the first marked with _ after it, or y for none"""
        elements = []
        if not pop('empty list'):
            while True:
                first = pop('first element') is not None
                label = pop('ident')
                element = pop_type()
                elements.append(Node('raw', label.args[0] + ': ' + show(element)) if label and element else element)
                if first:
                    break
            elements.reverse()
        return elements

    def bound_generics():
        """A bound generic's arguments, a list for each level of nesting, the last level's after y"""
        while pop('retroactive'):
            pass
        levels = []
        while True:
            level = []
            while (t := pop_type()) is not None:
                level.append(t)
            level.reverse()
            levels.append(level)
            if pop('empty list'):
                break
            if not pop('first element'):
                raise ValueError('generic arguments, then %s' % [n.kind for n in stack[-3:]])
        levels.reverse()
        return levels

    while i < len(tokens):
        c = tokens[i]
        i += 1
        if isinstance(c, tuple):
            n = resolve(*c)
            stack.append(n)
            if n.kind not in ('opaque descriptor', 'external opaque'):  # as in Demangler.cpp
                substitutions.append(n)
        elif c.isdigit():
            i -= 1
            has_words = False
            if c == '0':
                i += 1
                if peek() == '0':
                    raise ValueError('punycode')
                has_words = True
            identifier = ''
            while True:
                while has_words and isinstance(peek(), str) and peek().isalpha():
                    w = tokens[i]
                    i += 1
                    identifier += words[ord(w) - (97 if w.islower() else 65)]
                    has_words = w.islower()
                if peek() == '0':
                    i += 1
                    break
                n = natural()
                piece = ''.join(tokens[i:i + n])
                i += n
                identifier += piece
                start = -1  # the words in it, for later identifiers to repeat
                for j in range(len(piece) + 1):
                    ch = piece[j] if j < len(piece) else '\0'
                    if start >= 0 and (ch in '_\0' or (not piece[j - 1].isupper() and ch.isupper())):
                        if j - start >= 2 and len(words) < 26:
                            words.append(piece[start:j])
                        start = -1
                    if start < 0 and not ch.isdigit() and ch not in '_\0':
                        start = j
                if not has_words:
                    break
            n = Node('ident', identifier)
            stack.append(n)
            substitutions.append(n)
        elif c in 'VCOPa':
            name = stack.pop()
            if name.kind == 'local':
                name = name.args[0]
            context = stack.pop()
            if context.kind == 'ident':
                context = Node('module', context.args[0])
            n = Node('nominal', context, name.args[0] if name.kind == 'ident' else show(name))
            stack.append(n)
            substitutions.append(n)
        elif c == 's':
            stack.append(Node('module', 'Swift'))
        elif c == 'y':
            stack.append(Node('empty list'))
        elif c == '_':
            stack.append(Node('first element'))
        elif c == 'S':
            d = tokens[i]
            i += 1
            if d == 'o':
                stack.append(Node('module', '__C'))
            elif d == 'C':
                stack.append(Node('module', '__C_Synthesized'))
            elif d == 'g':
                n = Node('optional', pop_type())
                stack.append(n)
                substitutions.append(n)
            elif d == 'c':
                stack.append(Node('nominal', Node('module', 'Swift'), dict(T='Task', A='Actor', M='MainActor', P='TaskPriority',
                                                                     C='CheckedContinuation', g='TaskGroup', G='ThrowingTaskGroup',
                                                                     S='AsyncStream').get(tokens[i], 'Sc' + tokens[i])))
                i += 1
            else:
                repeat = 1
                if d.isdigit():  # one repeated, as S2S for String, String
                    i -= 1
                    repeat = natural()
                    d = tokens[i]
                    i += 1
                for _ in range(repeat):
                    stack.append(Node('nominal', Node('module', 'Swift'), STANDARD.get(d, 'S' + d)))
        elif c == 'A':
            repeat = -1
            while True:
                d = tokens[i]
                i += 1
                if isinstance(d, str) and d.isalpha():
                    for _ in range(max(repeat, 1)):
                        stack.append(substitutions[ord(d) - (97 if d.islower() else 65)])
                    repeat = -1
                    if d.isupper():
                        break
                elif d == '_':
                    stack.append(substitutions[repeat + 27])
                    break
                else:
                    i -= 1
                    repeat = natural()
        elif c == 'G':
            levels = bound_generics()
            n = Node('generic', pop_type(), levels)
            stack.append(n)
            substitutions.append(n)
        elif c == 't':
            stack.append(Node('tuple', pop_list()))
        elif c == 'x':
            stack.append(Node('param', 0, 0))
        elif c == 'q':
            if peek() == 'd':
                i += 1
                depth = index() + 1
                stack.append(Node('param', depth, index()))
            else:
                stack.append(Node('param', 0, index()))
        elif c == 'Q':
            d = tokens[i]
            i += 1
            if d == 'o':
                which = index()
                levels = bound_generics()
                n = Node('opaque', stack.pop(), which, levels)
                stack.append(n)
                substitutions.append(n)
            elif d == 'P':
                stack.append(Node('pack', pop_list()))
            elif d in 'zy':
                parameter = Node('param', 0, 0) if d == 'z' else Node('param', 0, index() + 1)
                pop_type()  # the protocol it's from, if given
                n = Node('assoc', parameter, pop('ident').args[0])
                stack.append(n)
                substitutions.append(n)
            else:
                raise ValueError('Q' + d)
        elif c == 'L' and peek() == 'L':  # a private declaration: its name, then the file's discriminator
            i += 1
            stack.pop()
            stack.append(Node('local', stack.pop()))
        elif c == 'L':
            index()
            stack.append(Node('local', stack.pop()))
        elif c == 'm':
            stack.append(Node('metatype', pop_type()))
        elif c == 'c' or (c == 'X' and tokens[i] in 'EABCLKfU'):
            # A function, or a non-escaping one, a block, a C function…: its parameters and result, each a
            # type or y for (), after any throws (K), async or Sendable (Y…) marks
            if c == 'X':
                i += 1
            parameters = Node('tuple', []) if pop('empty list') else pop_type()
            result = Node('tuple', []) if pop('empty list') else pop_type()
            stack.append(Node('function', parameters, result))
        elif c == 'p':
            stack.append(Node('existential', pop_list()))
        elif c == 'E':  # a type declared in an extension in another module: named by the type it extends
            stack.pop()
            stack.append(pop_type())
        elif c == 'B':
            d = tokens[i]
            i += 1
            if d == 'i':
                stack.append(Node('raw', 'Builtin.Int%d' % (index() - 1)))
            else:
                stack.append(Node('raw', 'Builtin.' + dict(D='DefaultActorStorage', o='NativeObject', b='BridgeObject',
                                                            p='RawPointer', O='UnknownObject', w='Word').get(d, d)))
        elif c == 'H':  # a conformance, which generic arguments carry when it's declared in another module
            d = tokens[i]
            i += 1
            if d in 'Pp':
                stack.append(Node('conformance ref', pop_type()))
            elif d == 'C':
                if not pop('empty list'):  # each conformance, the first followed by _
                    while stack and stack[-1].kind in ('first element', 'conformance'):
                        first = pop('first element') is not None
                        pop('conformance')
                        if first:
                            break
                if pop('conformance ref') is None:  # retroactive: the protocol, and the module declaring it
                    pop('ident', 'module')
                    pop_type()
                stack.append(Node('conformance', pop_type()))
            else:
                raise ValueError('H' + d)
        elif c == 'g':
            index()
            pop('conformance')
            stack.append(Node('retroactive'))
        elif c == 'K':
            pass
        elif c == 'Y':
            if tokens[i] in 'cK':
                pop_type()
            i += 1
        elif c in 'zhn':  # inout, __shared, __owned
            stack.append(Node('raw', {'z': 'inout ', 'h': '', 'n': ''}[c] + show(pop_type())))
        elif c == 'X' and tokens[i] in 'cl':  # NSObject & P, or AnyObject & P
            superclass = pop_type() if tokens[i] == 'c' else Node('raw', 'AnyObject')
            stack.append(Node('existential', [superclass] + pop_list()))
            i += 1
        elif c == 'X' and tokens[i] in 'pm':  # an existential's metatype, as Any.Type
            stack.append(Node('metatype', pop_type()))
            i += 1
        elif c == 'X' and tokens[i] in 'wou':  # weak, unowned, unowned(unsafe)
            stack.append(Node('raw', dict(w='weak ', o='unowned ', u='unowned(unsafe) ')[tokens[i]] + show(pop_type())))
            i += 1
        elif c == 'X':
            stack.append(Node('raw', c + tokens[i]))
            i += 1
        else:
            rest = ''.join(t if isinstance(t, str) else '?' for t in tokens[i:])
            stack.append(Node('raw', '«%s%s»' % (c, rest)))
            break
    stack = [n for n in stack if n.kind != 'empty list']
    return stack[0] if len(stack) == 1 else Node('raw', ' | '.join(show(n) for n in stack))


def mangled(a):
    """The mangled name at a, demangled, its symbolic references resolved"""
    o = file_offset(a)
    if data[o] == 0xff and data[o + 1] == 0x09:  # a function that picks the type, by the macOS it runs on
        return Node('raw', 'chosen by #available in the function at %x' % (address(o + 2) + struct.unpack_from('<i', data, o + 2)[0]))
    tokens = []
    while data[o]:
        c = data[o]
        if 1 <= c <= 0x17:
            tokens.append((c, o + 1, struct.unpack_from('<i', data, o + 1)[0]))
            o += 5
        elif 0x18 <= c <= 0x1f:
            tokens.append('?')
            o += 9
        else:
            tokens.append(chr(c))
            o += 1
    if tokens[:2] == ['$', 's']:  # a whole symbol's mangling, as a protocol's name can be
        tokens = tokens[2:]
    try:
        return demangle(tokens)
    except Exception as e:
        return Node('raw', 'couldn\'t demangle (%s): %s' % (e, ''.join(t if isinstance(t, str) else '<%x>' % t[0] for t in tokens)))


def matches(name):
    return pattern in name.lower()


def stubs():
    """Each stub's address and the symbol whose GOT slot it calls through"""
    found = []
    for name, size, decode in (('__auth_stubs', 16, 'add'), ('__stubs', 12, 'ldr')):
        if ('__TEXT', name) not in sections:
            continue
        start, total, off = sections[('__TEXT', name)]
        for k in range(total // size):
            a = start + size * k
            adrp, second = struct.unpack_from('<II', data, off + size * k)
            if adrp & 0x9f000000 != 0x90000000:
                continue
            page = ((adrp >> 5) & 0x7ffff) << 2 | (adrp >> 29) & 3
            if page & (1 << 20):
                page -= 1 << 21
            imm = (second >> 10) & 0xfff
            slot = (a & ~0xfff) + (page << 12) + (imm if decode == 'add' else imm * 8)
            found.append((a, binds.get(slot, 'got@%x' % slot)))
    names = demangle_symbols([s for _, s in found])
    return [(a, s, n) for (a, s), n in zip(found, names)]


if mode == 'types':
    start, size, _ = sections.get(('__TEXT', '__swift5_types'), (0, 0, 0))
    for k in range(size // 4):
        p = start + 4 * k
        r = i32(p)
        t = p + (r & ~3)
        if r & 3:
            t = rebases.get(t, t)
        name = context_name(t)
        if matches(name):
            print('%x %s %s' % (t, {16: 'class', 17: 'struct', 18: 'enum'}.get(u32(t) & 0x1f, '?'), name))
elif mode == 'fields':
    start, size, _ = sections.get(('__TEXT', '__swift5_fieldmd'), (0, 0, 0))
    p = start
    while p < start + size:
        record_size, count = u16(p + 10), u32(p + 12)
        name = show(mangled(relative(p))) if i32(p) else '?'
        q = p + 16
        if matches(name):
            print(name)
            for _ in range(count):
                field = cstring(relative(q + 8)) if i32(q + 8) else '?'
                print('    %s: %s' % (field, show(mangled(relative(q + 4))) if i32(q + 4) else '(no payload)'))
                q += record_size
        q = p + 16 + record_size * count
        p = q
elif mode == 'bodies':
    start, size, _ = sections.get(('__TEXT', '__swift5_assocty'), (0, 0, 0))
    p = start
    while p < start + size:
        conforming = show(mangled(relative(p)))
        count, record_size = u32(p + 8), u32(p + 12)
        if matches(conforming):
            protocol = show(mangled(relative(p + 4)))
            for k in range(count):
                q = p + 16 + record_size * k
                print('%s: %s.%s = %s\n' % (conforming, protocol, cstring(relative(q)), show(mangled(relative(q + 4)))))
        p += 16 + record_size * count
elif mode == 'stubs':
    for a, symbol, name in stubs():
        if matches(name) or matches(symbol):
            print('%x %s' % (a, name))
elif mode == 'callers':
    wanted = {a: name for a, symbol, name in stubs() if matches(name) or matches(symbol)}
    if not os.path.exists(disassembly_path):
        with open(disassembly_path, 'w') as f:
            subprocess.run(['xcrun', 'llvm-objdump', '--macho', '-d', '--no-show-raw-insn', thin], stdout=f, check=True)
    lines = open(disassembly_path).read().split('\n')
    function = None
    for n, line in enumerate(lines):
        if 'pacibsp' in line or line.endswith('stp\tx29, x30, [sp, #-0x10]!'):
            function = line.split(':')[0]
        m = re.search(r'\tb(?:l)?\t0x([0-9a-f]+)$', line)
        if m and int(m.group(1), 16) in wanted:
            print('== %s, from the function at %s' % (wanted[int(m.group(1), 16)], function))
            print('\n'.join(lines[max(0, n - 8):n + 1]) + '\n')
elif mode == 'opaque':
    for t in opaque_underlying(int(sys.argv[3], 16)):
        print(show(t))
