module glow.xbuf;

import core.stdc.stdlib;
import core.stdc.string;

version(linux) {
    extern(C) int getpagesize();
}

immutable uint PAGE_SIZE;

shared static this() {
    version (linux) {
        PAGE_SIZE = getpagesize();
    }
    else {
        static assert(0, "Cannot figure out the page size on this OS");
    }
}

/// XBuf - extensible self-loading buffer
struct XBuf {
@nogc nothrow:
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
    this(uint capacity, uint minLoading, scope int delegate(ubyte[]) nothrow @nogc loader, uint growBy = 0) {
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
    ubyte opIndex(size_t idx) {
        assert(idx < len);
        return ptr[idx];
    }

    ///
    ubyte[] opSlice(size_t start, size_t end) {
        assert(start <= end);
        assert(end <= len);
        return ptr[start..end];
    }

    ///
    size_t size() { return len; }

    ///
    size_t capacity() { return _capacity; }

    ///
    size_t minLoading(){ return _minLoading; }

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
    assert(buf.size == 50);
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
    assert(buf.size == 50);
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
    assert(buf.size == 50);
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
    assert(bnull.size == 0);
    assert(bnull.growBy == PAGE_SIZE);
    bnull.compact(0);
    assert(bnull.size == 0);
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
    assert(bneg.size == 1);
    assert(bneg[0] == 1);
    assert(bneg.load() == -1);
    assert(bneg.capacity == 5);
    assert(bneg.size == 1);
}

unittest {
    assert(PAGE_SIZE > 0);
    assert(((PAGE_SIZE-1) & PAGE_SIZE) == 0);
}