import Foundation

public protocol Coding {
    init(decoder: Decoder)
    func encode(_ encoder: Encoder)
}

private final class EncodableTypeStore {
    var dict: [Int32 : (Decoder) -> Coding] = [:]
    
    func decode(_ typeHash: Int32, decoder: Decoder) -> Coding? {
        if let typeDecoder = self.dict[typeHash] {
            return typeDecoder(decoder)
        } else {
            return nil
        }
    }
}

private let _typeStore = EncodableTypeStore()
private let typeStore = { () -> EncodableTypeStore in
    return _typeStore
}()

public func declareEncodable(_ type: Any.Type, f: @escaping(Decoder) -> Coding) {
    let string = "\(type)"
    let hash = murMurHashString32(string)
    if typeStore.dict[hash] != nil {
        assertionFailure("Encodable type hash collision for \(type)")
    }
    typeStore.dict[murMurHashString32("\(type)")] = f
}

public func persistentHash32(_ string: String) -> Int32 {
    return murMurHashString32(string)
}

private let emptyMemory = malloc(1)!

public class MemoryBuffer: Equatable, CustomStringConvertible {
    var memory: UnsafeMutableRawPointer
    var capacity: Int
    var length: Int
    var freeWhenDone: Bool

    public init(copyOf buffer: MemoryBuffer) {
        self.memory = malloc(buffer.length)
        memcpy(self.memory, buffer.memory, buffer.length)
        self.capacity = buffer.length
        self.length = buffer.length
        self.freeWhenDone = true
    }
    
    public init(memory: UnsafeMutableRawPointer, capacity: Int, length: Int, freeWhenDone: Bool) {
        self.memory = memory
        self.capacity = capacity
        self.length = length
        self.freeWhenDone = freeWhenDone
    }
    
    public init(data: Data) {
        if data.count == 0 {
            self.memory = emptyMemory
            self.capacity = 0
            self.length = 0
            self.freeWhenDone = false
        } else {
            self.memory = malloc(data.count)!
            data.copyBytes(to: self.memory.assumingMemoryBound(to: UInt8.self), count: data.count)
            self.capacity = data.count
            self.length = data.count
            self.freeWhenDone = false
        }
    }
    
    public init() {
        self.memory = emptyMemory
        self.capacity = 0
        self.length = 0
        self.freeWhenDone = false
    }
    
    deinit {
        if self.freeWhenDone {
            free(self.memory)
        }
    }
    
    public var description: String {
        let hexString = NSMutableString()
        let bytes = self.memory.assumingMemoryBound(to: UInt8.self)
        for i in 0 ..< self.length {
            hexString.appendFormat("%02x", UInt(bytes[i]))
        }
        
        return hexString as String
    }
    
    public func makeData() -> Data {
        if self.length == 0 {
            return Data()
        } else {
            return Data(bytes: self.memory, count: self.length)
        }
    }
}

public func ==(lhs: MemoryBuffer, rhs: MemoryBuffer) -> Bool {
    return lhs.length == rhs.length && memcmp(lhs.memory, rhs.memory, lhs.length) == 0
}

public final class WriteBuffer: MemoryBuffer {
    public var offset = 0
    
    public override init() {
        super.init(memory: malloc(32), capacity: 32, length: 0, freeWhenDone: true)
    }
    
    public func makeReadBufferAndReset() -> ReadBuffer {
        let buffer = ReadBuffer(memory: self.memory, length: self.offset, freeWhenDone: true)
        self.memory = malloc(32)
        self.capacity = 32
        self.offset = 0
        return buffer
    }
    
    public func readBufferNoCopy() -> ReadBuffer {
        return ReadBuffer(memory: self.memory, length: self.offset, freeWhenDone: false)
    }
    
    override public func makeData() -> Data {
        return Data(bytes: self.memory.assumingMemoryBound(to: UInt8.self), count: self.offset)
    }
    
    public func reset() {
        self.offset = 0
    }
    
    public func write(_ data: UnsafeRawPointer, offset: Int, length: Int) {
        if self.offset + length > self.capacity {
            self.capacity = self.offset + length + 256
            if self.length == 0 {
                self.memory = malloc(self.capacity)!
            } else {
                self.memory = realloc(self.memory, self.capacity)
            }
        }
        memcpy(self.memory + self.offset, data + offset, length)
        self.offset += length
        self.length = self.offset
    }
    
    public func write(_ data: Data) {
        let length = data.count
        if self.offset + length > self.capacity {
            self.capacity = self.offset + length + 256
            if self.length == 0 {
                self.memory = malloc(self.capacity)!
            } else {
                self.memory = realloc(self.memory, self.capacity)
            }
        }
        data.copyBytes(to: self.memory.advanced(by: offset).assumingMemoryBound(to: UInt8.self), count: length)
        self.offset += length
        self.length = self.offset
    }
}

public final class ReadBuffer: MemoryBuffer {
    public var offset = 0
    
    public init(memory: UnsafeMutableRawPointer, length: Int, freeWhenDone: Bool) {
        super.init(memory: memory, capacity: length, length: length, freeWhenDone: freeWhenDone)
    }
    
    public init(memoryBufferNoCopy: MemoryBuffer) {
        super.init(memory: memoryBufferNoCopy.memory, capacity: memoryBufferNoCopy.length, length: memoryBufferNoCopy.length, freeWhenDone: false)
    }
    
    public func dataNoCopy() -> Data {
        return Data(bytesNoCopy: self.memory.assumingMemoryBound(to: UInt8.self), count: self.length, deallocator: .none)
    }
    
    public func read(_ data: UnsafeMutablePointer<Void>, offset: Int, length: Int) {
        memcpy(data + offset, self.memory.advanced(by: self.offset), length)
        self.offset += length
    }
    
    public func skip(_ length: Int) {
        self.offset += length
    }
    
    public func reset() {
        self.offset = 0
    }
    
    public func sharedBufferNoCopy() -> ReadBuffer {
        return ReadBuffer(memory: memory, length: length, freeWhenDone: false)
    }
}

private enum ValueType: Int8 {
    case Int32 = 0
    case Int64 = 1
    case Bool = 2
    case Double = 3
    case String = 4
    case Object = 5
    case Int32Array = 6
    case Int64Array = 7
    case ObjectArray = 8
    case ObjectDictionary = 9
    case Bytes = 10
    case Nil = 11
}

public final class Encoder {
    private let buffer = WriteBuffer()
    
    public init() {
    }
    
    public func memoryBuffer() -> MemoryBuffer {
        return self.buffer
    }
    
    public func makeReadBufferAndReset() -> ReadBuffer {
        return self.buffer.makeReadBufferAndReset()
    }
    
    public func readBufferNoCopy() -> ReadBuffer {
        return self.buffer.readBufferNoCopy()
    }
    
    public func makeData() -> Data {
        return self.buffer.makeData()
    }
    
    public func reset() {
        self.buffer.reset()
    }
    
    public func encodeKey(_ key: StaticString) {
        var length: Int8 = Int8(key.utf8CodeUnitCount)
        self.buffer.write(&length, offset: 0, length: 1)
        self.buffer.write(key.utf8Start, offset: 0, length: Int(length))
    }
    
    public func encodeNil(forKey key: StaticString) {
        self.encodeKey(key)
        var type: Int8 = ValueType.Nil.rawValue
        self.buffer.write(&type, offset: 0, length: 1)
    }
    
    public func encodeInt32(_ value: Int32, forKey key: StaticString) {
        self.encodeKey(key)
        var type: Int8 = ValueType.Int32.rawValue
        self.buffer.write(&type, offset: 0, length: 1)
        var v = value
        self.buffer.write(&v, offset: 0, length: 4)
    }
    
    public func encodeInt64(_ value: Int64, forKey key: StaticString) {
        self.encodeKey(key)
        var type: Int8 = ValueType.Int64.rawValue
        self.buffer.write(&type, offset: 0, length: 1)
        var v = value
        self.buffer.write(&v, offset: 0, length: 8)
    }
    
    public func encodeBool(_ value: Bool, forKey key: StaticString) {
        self.encodeKey(key)
        var type: Int8 = ValueType.Bool.rawValue
        self.buffer.write(&type, offset: 0, length: 1)
        var v: Int8 = value ? 1 : 0
        self.buffer.write(&v, offset: 0, length: 1)
    }
    
    public func encodeDouble(_ value: Double, forKey key: StaticString) {
        self.encodeKey(key)
        var type: Int8 = ValueType.Double.rawValue
        self.buffer.write(&type, offset: 0, length: 1)
        var v = value
        self.buffer.write(&v, offset: 0, length: 8)
    }
    
    public func encodeString(_ value: String, forKey key: StaticString) {
        self.encodeKey(key)
        var type: Int8 = ValueType.String.rawValue
        self.buffer.write(&type, offset: 0, length: 1)
        let data = value.data(using: .utf8, allowLossyConversion: true)!
        var length: Int32 = Int32(data.count)
        self.buffer.write(&length, offset: 0, length: 4)
        self.buffer.write(data)
    }
    
    public func encodeRootObject(_ value: Coding) {
        self.encodeObject(value, forKey: "_")
    }
    
    public func encodeObject(_ value: Coding, forKey key: StaticString) {
        self.encodeKey(key)
        var type: Int8 = ValueType.Object.rawValue
        self.buffer.write(&type, offset: 0, length: 1)
        
        let string = "\(type(of: value))"
        var typeHash: Int32 = murMurHashString32(string)
        self.buffer.write(&typeHash, offset: 0, length: 4)
        
        let innerEncoder = Encoder()
        value.encode(innerEncoder)
        
        var length: Int32 = Int32(innerEncoder.buffer.offset)
        self.buffer.write(&length, offset: 0, length: 4)
        self.buffer.write(innerEncoder.buffer.memory, offset: 0, length: Int(length))
    }
    
    public func encodeInt32Array(_ value: [Int32], forKey key: StaticString) {
        self.encodeKey(key)
        var type: Int8 = ValueType.Int32Array.rawValue
        self.buffer.write(&type, offset: 0, length: 1)
        var length: Int32 = Int32(value.count)
        self.buffer.write(&length, offset: 0, length: 4)
        value.withUnsafeBufferPointer { (data: UnsafeBufferPointer) -> Void in
            self.buffer.write(UnsafePointer<Void>(data.baseAddress!), offset: 0, length: Int(length) * 4)
            return
        }
    }
    
    public func encodeInt64Array(_ value: [Int64], forKey key: StaticString) {
        self.encodeKey(key)
        var type: Int8 = ValueType.Int64Array.rawValue
        self.buffer.write(&type, offset: 0, length: 1)
        var length: Int32 = Int32(value.count)
        self.buffer.write(&length, offset: 0, length: 4)
        value.withUnsafeBufferPointer { (data: UnsafeBufferPointer) -> Void in
            self.buffer.write(UnsafePointer<Void>(data.baseAddress!), offset: 0, length: Int(length) * 8)
            return
        }
    }
    
    public func encodeObjectArray<T: Coding>(_ value: [T], forKey key: StaticString) {
        self.encodeKey(key)
        var type: Int8 = ValueType.ObjectArray.rawValue
        self.buffer.write(&type, offset: 0, length: 1)
        var length: Int32 = Int32(value.count)
        self.buffer.write(&length, offset: 0, length: 4)
        let innerEncoder = Encoder()
        for object in value {
            var typeHash: Int32 = murMurHashString32("\(type(of: object))")
            self.buffer.write(&typeHash, offset: 0, length: 4)
            
            innerEncoder.reset()
            object.encode(innerEncoder)
            
            var length: Int32 = Int32(innerEncoder.buffer.offset)
            self.buffer.write(&length, offset: 0, length: 4)
            self.buffer.write(innerEncoder.buffer.memory, offset: 0, length: Int(length))
        }
    }
    
    public func encodeGenericObjectArray(_ value: [Coding], forKey key: StaticString) {
        self.encodeKey(key)
        var type: Int8 = ValueType.ObjectArray.rawValue
        self.buffer.write(&type, offset: 0, length: 1)
        var length: Int32 = Int32(value.count)
        self.buffer.write(&length, offset: 0, length: 4)
        let innerEncoder = Encoder()
        for object in value {
            var typeHash: Int32 = murMurHashString32("\(type(of: object))")
            self.buffer.write(&typeHash, offset: 0, length: 4)
            
            innerEncoder.reset()
            object.encode(innerEncoder)
            
            var length: Int32 = Int32(innerEncoder.buffer.offset)
            self.buffer.write(&length, offset: 0, length: 4)
            self.buffer.write(innerEncoder.buffer.memory, offset: 0, length: Int(length))
        }
    }
    
    public func encodeObjectDictionary<K, V: Coding where K: Coding, K: Hashable>(_ value: [K : V], forKey key: StaticString) {
        self.encodeKey(key)
        var type: Int8 = ValueType.ObjectDictionary.rawValue
        self.buffer.write(&type, offset: 0, length: 1)
        var length: Int32 = Int32(value.count)
        self.buffer.write(&length, offset: 0, length: 4)
        
        let innerEncoder = Encoder()
        for record in value {
            var keyTypeHash: Int32 = murMurHashString32("\(type(of: record.0))")
            self.buffer.write(&keyTypeHash, offset: 0, length: 4)
            innerEncoder.reset()
            record.0.encode(innerEncoder)
            var keyLength: Int32 = Int32(innerEncoder.buffer.offset)
            self.buffer.write(&keyLength, offset: 0, length: 4)
            self.buffer.write(innerEncoder.buffer.memory, offset: 0, length: Int(keyLength))
            
            var valueTypeHash: Int32 = murMurHashString32("\(type(of: record.1))")
            self.buffer.write(&valueTypeHash, offset: 0, length: 4)
            innerEncoder.reset()
            record.1.encode(innerEncoder)
            var valueLength: Int32 = Int32(innerEncoder.buffer.offset)
            self.buffer.write(&valueLength, offset: 0, length: 4)
            self.buffer.write(innerEncoder.buffer.memory, offset: 0, length: Int(valueLength))
        }
    }
    
    public func encodeBytes(_ bytes: WriteBuffer, forKey key: StaticString) {
        self.encodeKey(key)
        var type: Int8 = ValueType.Bytes.rawValue
        self.buffer.write(&type, offset: 0, length: 1)
        var bytesLength: Int32 = Int32(bytes.offset)
        self.buffer.write(&bytesLength, offset: 0, length: 4)
        self.buffer.write(bytes.memory, offset: 0, length: bytes.offset)
    }
    
    public func encodeBytes(_ bytes: ReadBuffer, forKey key: StaticString) {
        self.encodeKey(key)
        var type: Int8 = ValueType.Bytes.rawValue
        self.buffer.write(&type, offset: 0, length: 1)
        var bytesLength: Int32 = Int32(bytes.offset)
        self.buffer.write(&bytesLength, offset: 0, length: 4)
        self.buffer.write(bytes.memory, offset: 0, length: bytes.offset)
    }
    
    public func encodeBytes(_ bytes: MemoryBuffer, forKey key: StaticString) {
        self.encodeKey(key)
        var type: Int8 = ValueType.Bytes.rawValue
        self.buffer.write(&type, offset: 0, length: 1)
        var bytesLength: Int32 = Int32(bytes.length)
        self.buffer.write(&bytesLength, offset: 0, length: 4)
        self.buffer.write(bytes.memory, offset: 0, length: bytes.length)
    }

    public let sharedWriteBuffer = WriteBuffer()
}

public final class Decoder {
    private let buffer: MemoryBuffer
    private var offset: Int = 0
    
    public init(buffer: MemoryBuffer) {
        self.buffer = buffer
    }
    
    private class func skipValue(_ bytes: UnsafePointer<Int8>, offset: inout Int, length: Int, valueType: ValueType) {
        switch valueType {
            case .Int32:
                offset += 4
            case .Int64:
                offset += 8
            case .Bool:
                offset += 1
            case .Double:
                offset += 8
            case .String:
                var length: Int32 = 0
                memcpy(&length, bytes + offset, 4)
                offset += 4 + Int(length)
            case .Object:
                var length: Int32 = 0
                memcpy(&length, bytes + (offset + 4), 4)
                offset += 8 + Int(length)
            case .Int32Array:
                var length: Int32 = 0
                memcpy(&length, bytes + offset, 4)
                offset += 4 + Int(length) * 4
            case .Int64Array:
                var length: Int32 = 0
                memcpy(&length, bytes + offset, 4)
                offset += 4 + Int(length) * 8
            case .ObjectArray:
                var length: Int32 = 0
                memcpy(&length, bytes + offset, 4)
                offset += 4
                var i: Int32 = 0
                while i < length {
                    var objectLength: Int32 = 0
                    memcpy(&objectLength, bytes + (offset + 4), 4)
                    offset += 8 + Int(objectLength)
                    i += 1
                }
            case .ObjectDictionary:
                var length: Int32 = 0
                memcpy(&length, bytes + offset, 4)
                offset += 4
                var i: Int32 = 0
                while i < length {
                    var keyLength: Int32 = 0
                    memcpy(&keyLength, bytes + (offset + 4), 4)
                    offset += 8 + Int(keyLength)
                    
                    var valueLength: Int32 = 0
                    memcpy(&valueLength, bytes + (offset + 4), 4)
                    offset += 8 + Int(valueLength)
                    i += 1
                }
            case .Bytes:
                var length: Int32 = 0
                memcpy(&length, bytes + offset, 4)
                offset += 4 + Int(length)
            case .Nil:
                break
        }
    }
    
    private class func positionOnKey(_ rawBytes: UnsafeRawPointer, offset: inout Int, maxOffset: Int, length: Int, key: StaticString, valueType: ValueType) -> Bool
    {
        let bytes = rawBytes.assumingMemoryBound(to: Int8.self)
        
        let startOffset = offset
        
        let keyLength: Int = key.utf8CodeUnitCount
        while (offset < maxOffset) {
            let readKeyLength = bytes[offset]
            assert(readKeyLength >= 0)
            offset += 1
            offset += Int(readKeyLength)
            
            let readValueType = bytes[offset]
            offset += 1
            
            if keyLength == Int(readKeyLength) && memcmp(bytes + (offset - Int(readKeyLength) - 1), key.utf8Start, keyLength) == 0 {
                if readValueType == valueType.rawValue {
                    return true
                } else if readValueType == ValueType.Nil.rawValue {
                    return false
                } else {
                    skipValue(bytes, offset: &offset, length: length, valueType: ValueType(rawValue: readValueType)!)
                }
            } else {
                skipValue(bytes, offset: &offset, length: length, valueType: ValueType(rawValue: readValueType)!)
            }
        }
        
        if (startOffset != 0) {
            offset = 0
            return positionOnKey(bytes, offset: &offset, maxOffset: startOffset, length: length, key: key, valueType: valueType)
        }
        
        return false
    }
    
    private class func positionOnKey(_ bytes: UnsafePointer<Int8>, offset: inout Int, maxOffset: Int, length: Int, key: Int16, valueType: ValueType) -> Bool
    {
        var keyValue = key
        let startOffset = offset
        
        let keyLength: Int = 2
        while (offset < maxOffset)
        {
            let readKeyLength = bytes[offset]
            offset += 1
            offset += Int(readKeyLength)
            
            let readValueType = bytes[offset]
            offset += 1
            
            if readValueType != valueType.rawValue || keyLength != Int(readKeyLength) || memcmp(bytes + (offset - Int(readKeyLength) - 1), &keyValue, keyLength) != 0 {
                skipValue(bytes, offset: &offset, length: length, valueType: ValueType(rawValue: readValueType)!)
            } else {
                return true
            }
        }
        
        if (startOffset != 0)
        {
            offset = 0
            return positionOnKey(bytes, offset: &offset, maxOffset: startOffset, length: length, key: key, valueType: valueType)
        }
        
        return false
    }
    
    public func decodeInt32ForKey(_ key: StaticString) -> Int32 {
        if Decoder.positionOnKey(self.buffer.memory, offset: &self.offset, maxOffset: self.buffer.length, length: self.buffer.length, key: key, valueType: .Int32) {
            var value: Int32 = 0
            memcpy(&value, self.buffer.memory + self.offset, 4)
            self.offset += 4
            return value
        } else {
            return 0
        }
    }
    
    public func decodeInt32ForKey(_ key: StaticString) -> Int32? {
        if Decoder.positionOnKey(self.buffer.memory, offset: &self.offset, maxOffset: self.buffer.length, length: self.buffer.length, key: key, valueType: .Int32) {
            var value: Int32 = 0
            memcpy(&value, self.buffer.memory + self.offset, 4)
            self.offset += 4
            return value
        } else {
            return nil
        }
    }
    
    public func decodeInt64ForKey(_ key: StaticString) -> Int64 {
        if Decoder.positionOnKey(self.buffer.memory, offset: &self.offset, maxOffset: self.buffer.length, length: self.buffer.length, key: key, valueType: .Int64) {
            var value: Int64 = 0
            memcpy(&value, self.buffer.memory + self.offset, 8)
            self.offset += 8
            return value
        } else {
            return 0
        }
    }
    
    public func decodeInt64ForKey(_ key: StaticString) -> Int64? {
        if Decoder.positionOnKey(self.buffer.memory, offset: &self.offset, maxOffset: self.buffer.length, length: self.buffer.length, key: key, valueType: .Int64) {
            var value: Int64 = 0
            memcpy(&value, self.buffer.memory + self.offset, 8)
            self.offset += 8
            return value
        } else {
            return nil
        }
    }
    
    public func decodeBoolForKey(_ key: StaticString) -> Bool {
        if Decoder.positionOnKey(self.buffer.memory, offset: &self.offset, maxOffset: self.buffer.length, length: self.buffer.length, key: key, valueType: .Bool) {
            var value: Int8 = 0
            memcpy(&value, self.buffer.memory + self.offset, 1)
            self.offset += 1
            return value != 0
        } else {
            return false
        }
    }
    
    public func decodeDoubleForKey(_ key: StaticString) -> Double {
        if Decoder.positionOnKey(self.buffer.memory, offset: &self.offset, maxOffset: self.buffer.length, length: self.buffer.length, key: key, valueType: .Double) {
            var value: Double = 0
            memcpy(&value, self.buffer.memory + self.offset, 8)
            self.offset += 8
            return value
        } else {
            return 0
        }
    }
    
    public func decodeStringForKey(_ key: StaticString) -> String {
        if Decoder.positionOnKey(self.buffer.memory, offset: &self.offset, maxOffset: self.buffer.length, length: self.buffer.length, key: key, valueType: .String) {
            var length: Int32 = 0
            memcpy(&length, self.buffer.memory + self.offset, 4)
            let data = Data(bytes: self.buffer.memory.assumingMemoryBound(to: UInt8.self).advanced(by: self.offset + 4), count: Int(length))
            self.offset += 4 + Int(length)
            return String(data: data, encoding: .utf8) ?? ""
        } else {
            return ""
        }
    }
    
    public func decodeStringForKey(_ key: StaticString) -> String? {
        if Decoder.positionOnKey(self.buffer.memory, offset: &self.offset, maxOffset: self.buffer.length, length: self.buffer.length, key: key, valueType: .String) {
            var length: Int32 = 0
            memcpy(&length, self.buffer.memory + self.offset, 4)
            let data = Data(bytes: self.buffer.memory.assumingMemoryBound(to: UInt8.self).advanced(by: self.offset + 4), count: Int(length))
            self.offset += 4 + Int(length)
            return String(data: data, encoding: .utf8)
        } else {
            return nil
        }
    }
    
    public func decodeRootObject() -> Coding? {
        return self.decodeObjectForKey("_")
    }
    
    public func decodeObjectForKey(_ key: StaticString) -> Coding? {
        if Decoder.positionOnKey(self.buffer.memory, offset: &self.offset, maxOffset: self.buffer.length, length: self.buffer.length, key: key, valueType: .Object) {
            var typeHash: Int32 = 0
            memcpy(&typeHash, self.buffer.memory + self.offset, 4)
            self.offset += 4
            
            var length: Int32 = 0
            memcpy(&length, self.buffer.memory + self.offset, 4)

            let innerDecoder = Decoder(buffer: ReadBuffer(memory: self.buffer.memory + (self.offset + 4), length: Int(length), freeWhenDone: false))
            self.offset += 4 + Int(length)
            
            return typeStore.decode(typeHash, decoder: innerDecoder)
        } else {
            return nil
        }
    }
    
    public func decodeObjectForKey(_ key: StaticString, decoder: (Decoder) -> Coding) -> Coding? {
        if Decoder.positionOnKey(self.buffer.memory, offset: &self.offset, maxOffset: self.buffer.length, length: self.buffer.length, key: key, valueType: .Object) {
            var typeHash: Int32 = 0
            memcpy(&typeHash, self.buffer.memory + self.offset, 4)
            self.offset += 4
            
            var length: Int32 = 0
            memcpy(&length, self.buffer.memory + self.offset, 4)
            
            let innerDecoder = Decoder(buffer: ReadBuffer(memory: self.buffer.memory + (self.offset + 4), length: Int(length), freeWhenDone: false))
            self.offset += 4 + Int(length)
            
            return decoder(innerDecoder)
        } else {
            return nil
        }
    }
    
    public func decodeInt32ArrayForKey(_ key: StaticString) -> [Int32] {
        if Decoder.positionOnKey(self.buffer.memory, offset: &self.offset, maxOffset: self.buffer.length, length: self.buffer.length, key: key, valueType: .Int32Array) {
            var length: Int32 = 0
            memcpy(&length, self.buffer.memory + self.offset, 4)
            var array: [Int32] = []
            array.reserveCapacity(Int(length))
            var i: Int32 = 0
            while i < length {
                var element: Int32 = 0
                memcpy(&element, self.buffer.memory + (self.offset + 4 + 4 * Int(i)), 4)
                array.append(element)
                i += 1
            }
            self.offset += 4 + Int(length) * 4
            return array
        } else {
            return []
        }
    }
    
    public func decodeInt64ArrayForKey(_ key: StaticString) -> [Int64] {
        if Decoder.positionOnKey(self.buffer.memory, offset: &self.offset, maxOffset: self.buffer.length, length: self.buffer.length, key: key, valueType: .Int64Array) {
            var length: Int32 = 0
            memcpy(&length, self.buffer.memory + self.offset, 4)
            var array: [Int64] = []
            array.reserveCapacity(Int(length))
            var i: Int32 = 0
            while i < length {
                var element: Int64 = 0
                memcpy(&element, self.buffer.memory + (self.offset + 4 + 8 * Int(i)), 8)
                array.append(element)
                i += 1
            }
            self.offset += 4 + Int(length) * 8
            return array
        } else {
            return []
        }
    }
    
    public func decodeObjectArrayWithDecoderForKey<T where T: Coding>(_ key: StaticString) -> [T] {
        if Decoder.positionOnKey(self.buffer.memory, offset: &self.offset, maxOffset: self.buffer.length, length: self.buffer.length, key: key, valueType: .ObjectArray) {
            var length: Int32 = 0
            memcpy(&length, self.buffer.memory + self.offset, 4)
            self.offset += 4
            
            var array: [T] = []
            array.reserveCapacity(Int(length))
            
            let failed = false
            var i: Int32 = 0
            while i < length {
                var typeHash: Int32 = 0
                memcpy(&typeHash, self.buffer.memory + self.offset, 4)
                self.offset += 4
                
                var objectLength: Int32 = 0
                memcpy(&objectLength, self.buffer.memory + self.offset, 4)
                
                let innerDecoder = Decoder(buffer: ReadBuffer(memory: self.buffer.memory + (self.offset + 4), length: Int(objectLength), freeWhenDone: false))
                self.offset += 4 + Int(objectLength)
                
                if !failed {
                    array.append(T(decoder: innerDecoder))
                }
                
                i += 1
            }
            
            if failed {
                return []
            } else {
                return array
            }
        } else {
            return []
        }
    }
    
    public func decodeObjectArrayForKey<T where T: Coding>(_ key: StaticString) -> [T] {
        if Decoder.positionOnKey(self.buffer.memory, offset: &self.offset, maxOffset: self.buffer.length, length: self.buffer.length, key: key, valueType: .ObjectArray) {
            var length: Int32 = 0
            memcpy(&length, self.buffer.memory + self.offset, 4)
            self.offset += 4
            
            var array: [T] = []
            array.reserveCapacity(Int(length))
            
            var failed = false
            var i: Int32 = 0
            while i < length {
                var typeHash: Int32 = 0
                memcpy(&typeHash, self.buffer.memory + self.offset, 4)
                self.offset += 4
                
                var objectLength: Int32 = 0
                memcpy(&objectLength, self.buffer.memory + self.offset, 4)
                
                let innerDecoder = Decoder(buffer: ReadBuffer(memory: self.buffer.memory + (self.offset + 4), length: Int(objectLength), freeWhenDone: false))
                self.offset += 4 + Int(objectLength)
                
                if !failed {
                    if let object = typeStore.decode(typeHash, decoder: innerDecoder) as? T {
                        array.append(object)
                    } else {
                        failed = true
                    }
                }
                
                i += 1
            }
            
            if failed {
                return []
            } else {
                return array
            }
        } else {
            return []
        }
    }

    public func decodeObjectArrayForKey(_ key: StaticString) -> [Coding] {
        if Decoder.positionOnKey(self.buffer.memory, offset: &self.offset, maxOffset: self.buffer.length, length: self.buffer.length, key: key, valueType: .ObjectArray) {
            var length: Int32 = 0
            memcpy(&length, self.buffer.memory + self.offset, 4)
            self.offset += 4
            
            var array: [Coding] = []
            array.reserveCapacity(Int(length))
            
            var failed = false
            var i: Int32 = 0
            while i < length {
                var typeHash: Int32 = 0
                memcpy(&typeHash, self.buffer.memory + self.offset, 4)
                self.offset += 4
                
                var objectLength: Int32 = 0
                memcpy(&objectLength, self.buffer.memory + self.offset, 4)
                
                let innerDecoder = Decoder(buffer: ReadBuffer(memory: self.buffer.memory + (self.offset + 4), length: Int(objectLength), freeWhenDone: false))
                self.offset += 4 + Int(objectLength)
                
                if !failed {
                    if let object = typeStore.decode(typeHash, decoder: innerDecoder) {
                        array.append(object)
                    } else {
                        failed = true
                    }
                }
                
                i += 1
            }
            
            if failed {
                return []
            } else {
                return array
            }
        } else {
            return []
        }
    }
    
    public func decodeObjectDictionaryForKey<K, V: Coding where K: Coding, K: Hashable>(_ key: StaticString) -> [K : V] {
        if Decoder.positionOnKey(self.buffer.memory, offset: &self.offset, maxOffset: self.buffer.length, length: self.buffer.length, key: key, valueType: .ObjectDictionary) {
            var length: Int32 = 0
            memcpy(&length, self.buffer.memory + self.offset, 4)
            self.offset += 4
            
            var dictionary: [K : V] = [:]
            
            var failed = false
            var i: Int32 = 0
            while i < length {
                var keyHash: Int32 = 0
                memcpy(&keyHash, self.buffer.memory + self.offset, 4)
                self.offset += 4
                
                var keyLength: Int32 = 0
                memcpy(&keyLength, self.buffer.memory + self.offset, 4)
                
                var innerDecoder = Decoder(buffer: ReadBuffer(memory: self.buffer.memory + (self.offset + 4), length: Int(keyLength), freeWhenDone: false))
                self.offset += 4 + Int(keyLength)
                
                let key = failed ? nil : (typeStore.decode(keyHash, decoder: innerDecoder) as? K)
                    
                var valueHash: Int32 = 0
                memcpy(&valueHash, self.buffer.memory + self.offset, 4)
                self.offset += 4
                
                var valueLength: Int32 = 0
                memcpy(&valueLength, self.buffer.memory + self.offset, 4)
                
                innerDecoder = Decoder(buffer: ReadBuffer(memory: self.buffer.memory + (self.offset + 4), length: Int(valueLength), freeWhenDone: false))
                self.offset += 4 + Int(valueLength)
                
                let value = failed ? nil : (typeStore.decode(valueHash, decoder: innerDecoder) as? V)
                
                if let key = key, let value = value {
                    dictionary[key] = value
                } else {
                    failed = true
                }
                
                i += 1
            }
            
            if failed {
                return [:]
            } else {
                return dictionary
            }
        } else {
            return [:]
        }
    }
    
    public func decodeBytesForKeyNoCopy(_ key: StaticString) -> ReadBuffer? {
        if Decoder.positionOnKey(self.buffer.memory, offset: &self.offset, maxOffset: self.buffer.length, length: self.buffer.length, key: key, valueType: .Bytes) {
            var length: Int32 = 0
            memcpy(&length, self.buffer.memory + self.offset, 4)
            self.offset += 4 + Int(length)
            return ReadBuffer(memory: self.buffer.memory.advanced(by: self.offset - Int(length)), length: Int(length), freeWhenDone: false)
        } else {
            return nil
        }
    }
    
    public func decodeBytesForKey(_ key: StaticString) -> ReadBuffer? {
        if Decoder.positionOnKey(self.buffer.memory, offset: &self.offset, maxOffset: self.buffer.length, length: self.buffer.length, key: key, valueType: .Bytes) {
            var length: Int32 = 0
            memcpy(&length, self.buffer.memory + self.offset, 4)
            self.offset += 4 + Int(length)
            let copyBytes = malloc(Int(length))!
            memcpy(copyBytes, self.buffer.memory.advanced(by: self.offset - Int(length)), Int(length))
            return ReadBuffer(memory: copyBytes, length: Int(length), freeWhenDone: true)
        } else {
            return nil
        }
    }
}
