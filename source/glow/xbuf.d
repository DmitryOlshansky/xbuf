module glow.xbuf;

import core.stdc.stdlib;
import core.stdc.string;
import core.memory;
import std.algorithm;

version(linux) {
    extern(C) int getpagesize();
}
version(Windows) {
    import core.sys.windows.winbase;
}

immutable uint PAGE_SIZE;

shared static this() {
    version (linux) {
        PAGE_SIZE = getpagesize();
    }
    else version(OSX) {
        import core.sys.darwin.sys.sysctl;
        import core.stdc.stdio;
        int[6] mib; 
        mib[0] = CTL_HW;
        mib[1] = HW_PAGESIZE;

        int pagesize;
        size_t length;
        length = pagesize.sizeof;
        if (sysctl (mib.ptr, 2, &pagesize, &length, null, 0) < 0) {
            perror("cannot get page size");
            abort();
        }
        PAGE_SIZE = pagesize;
    }
    else version(Windows) {
        SYSTEM_INFO si;
        GetSystemInfo(&si);
        PAGE_SIZE = si.dwPageSize;
    }
    else {
        static assert(0, "Cannot figure out the page size on this OS");
    }
}

/// Plain realloc-based buffer for plain old data types, serves as OutputRange
struct Buffer(T)
if(__traits(isPOD, T)) {
private:
	T* mem;
	size_t cap;
	size_t offset;
public:
@trusted:
pure:
	this(size_t initial) {
		mem = cast(T*)pureMalloc(initial*T.sizeof);
		cap = initial;
	}

    /// Output range primitive, puts slice of data into buffer
	void put(const(T)[] slice) {
        pragma(inline, true);
		this ~= slice;
	}

    /// Output range primitive, puts value into the buffer
    void put(T value) {
        pragma(inline, true);
        if (offset == cap) {
			extend(offset+1);
		}
        mem[offset++] = value;
    }

    /// Append operator, simillar to put
	ref opOpAssign(string op:"~")(const(T)[] slice) {
		pragma(inline, true);
        if (offset + slice.length > cap) {
			extend(offset + slice.length);
		}
		memmove(mem + offset, slice.ptr, slice.length * T.sizeof);
		offset += slice.length;
	}

    private void extend(size_t minRequired) {
        pragma(inline, false);
        cap =  max(cap * 2, minRequired);
        mem = cast(T*) pureRealloc(mem, cap * T.sizeof);
    }

    /// reset accumulation
	void clear() {
		offset = 0;
	}

    /// length of accumulated buffer
	size_t length() { return offset; }

    /// A slice into accumulated buffer of data
	T[] data() {
		return mem[0..offset];
	}

	@disable this(this);

	~this() {
		pureFree(mem);
	}
}

/// XBuf - extensible self-loading buffer
struct XBuf {
nothrow:
private:
    ubyte* ptr;
    uint _capacity;
    uint len;
    uint growBy;
    uint _minLoading;
    int delegate(ubyte[]) loader;
public:
    @disable this(this);
    ///
    this(uint capacity, uint minLoading, int delegate(ubyte[]) nothrow loader, uint growBy = 0) {
        assert(capacity > 0);
        assert(minLoading > 0);
        assert(minLoading < capacity);
        if (growBy == 0) {
            this.growBy = PAGE_SIZE;
        } else {
            this.growBy = growBy;
        }
        this.ptr = cast(ubyte*)malloc(capacity);
        this.len = 0;
        this._capacity = capacity;
        this._minLoading = minLoading;
        this.loader = loader;
    }

    ///
    ubyte opIndex()(size_t idx) {
        pragma(inline, true);
        assert(idx < len);
        return ptr[idx];
    }

    ///
    ubyte[] opSlice()(size_t start, size_t end) {
        pragma(inline, true);
        assert(start <= end);
        assert(end <= len);
        return ptr[start..end];
    }

    /++
        Copy over data from start..length to dest and continue loading into dest until it's full.
        Depending on dest.length:
        dest.length <= length - start
        only copy dest.length bytes of data over and return start + dest.length
        dest.length > length - start
        copy length - start bytes and then call loader on the rest of the buffer until its filled
        return len
        in case of end of stream return 0
        and negative value on loading error
    +/
    ptrdiff_t fork(size_t start, ubyte[] dest) {
        assert(start <= len);
        size_t avail = len - start;
        assert(dest.length >= avail);
        dest[0..avail] = ptr[start..len];
        for (size_t j = avail; j < dest.length;) {
            auto res = loader(dest[j..$]);
            if (res < 0) return res;
            if (res == 0) return j;
            j += res;
        }
        return dest.length;
    }

    ///
    size_t length()() {
        pragma(inline, true);
        return len;
    }

    ///
    size_t capacity()() { return _capacity; }

    ///
    size_t minLoading()(){ return _minLoading; }

    ///
    int load() {
        if (_capacity - len < _minLoading) {
            resize(len + _minLoading);
        }
        int ret = loader(ptr[len.._capacity]);
        if (ret <= 0) return ret;
        len += ret;
        return ret;
    }

    ///
    void resize(uint capacity) {
        assert(len < capacity);
        uint roundedCapacity = (capacity + growBy-1)/growBy*growBy;
        this.ptr = cast(ubyte*)realloc(this.ptr, roundedCapacity);
        this._capacity = roundedCapacity;
    }

    ///
    void compact(size_t lastValid) {
        assert(lastValid <= len);
        if (len != lastValid)
            memmove(ptr, ptr + lastValid, len - lastValid);
        len -= lastValid;
    }

    ///
    ~this() {
        free(ptr);
    }
}

///
unittest {
    // capacity 32, min loading size 16, grow granularity 10
    XBuf buf = XBuf(32, 16, (slice) { 
        foreach (i, ref s; slice) {
            s = cast(ubyte)i;
        }
        return cast(int)slice.length;
    }, 10);
    buf.load();
    // loaded full buffer of 0..32
    foreach (i; 0..32) {
        assert(buf[i] == i);
    }
    buf.load();
    // capacity is 32+16 rounded to 10
    assert(buf.length == 50);
    foreach (i; 0..32){
        assert(buf[i] == i);
    }
    foreach (i; 32..50) {
        assert(buf[i] == i - 32);
    }
    buf.compact(20);
    // all of the first 20 bytes were overwritten
    foreach (i; 20..32) {
        assert(buf[i-20] == i);
    }
}

unittest {
    XBuf buf = XBuf(32, 16, (slice) { 
        foreach (i, ref s; slice) {
            s = cast(ubyte)i;
        }
        return cast(int)slice.length;
    }, 10);
    buf.load();
    assert(buf.len == 32);
    assert(buf.capacity == 32);
    assert(buf.minLoading == 16);
    foreach (i; 0..32) {
        assert(buf[i] == i);
    }
    buf.load();
    assert(buf.length == 50);
    foreach (i; 0..32) {
        assert(buf[i] == i);
    }
    foreach (i; 32..50) {
        assert(buf[i] == i - 32);
    }
    buf.compact(20);
    foreach (i; 20..32) {
        assert(buf[i-20] == i);
    }
    buf.load();
    assert(buf.length == 50);
    foreach (i; 30..50) {
        assert(buf[i] == i-30);
    }
    buf.compact(50);
    buf.load();
    foreach (i; 0..50) {
        assert(buf[i] == i);
    }
    assert(buf[0..3] == [0, 1, 2]);
}

unittest {
    XBuf bnull = XBuf(10, 5, (slice) {
        return 0;
    });
    assert(bnull.load() == 0);
    assert(bnull.length == 0);
    assert(bnull.growBy == PAGE_SIZE);
    bnull.compact(0);
    assert(bnull.length == 0);
}

unittest {
    bool first = true;
    XBuf bneg = XBuf(5, 1, (slice) {
        if (first) {
            first = false;
            slice[0] = 1;
            return 1;
        } else {
            return -1;
        }
    });
    assert(bneg.load() == 1);
    assert(bneg.length == 1);
    assert(bneg[0] == 1);
    assert(bneg.load() == -1);
    assert(bneg.capacity == 5);
    assert(bneg.length == 1);
}

unittest {
    import std.algorithm, std.range;
    int i = 0;
    XBuf buf = XBuf (8, 2, (slice) {
        slice[0] = cast(ubyte)i++;
        return 1;
    });
    buf.load();
    buf.load();
    ubyte[] data = new ubyte[10];
    buf.fork(1, data);
    assert(equal(data, iota(1, 11)));
    assert(buf.length == 2);
}



unittest {
    assert(PAGE_SIZE > 0);
    assert(((PAGE_SIZE-1) & PAGE_SIZE) == 0);
}