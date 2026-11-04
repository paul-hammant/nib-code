pub const prelude =
    \\(() => {
    \\  const epoch = globalThis.__replayEpoch, time = globalThis.__replayTime, random = globalThis.__replayRandom;
    \\  delete globalThis.__replayEpoch; delete globalThis.__replayTime; delete globalThis.__replayRandom;
    \\  const NativeDate = Date;
    \\  function FixedDate(...args) {
    \\    time();
    \\    if (!new.target) return new NativeDate(epoch).toString();
    \\    return Reflect.construct(NativeDate, args.length ? args : [epoch], new.target);
    \\  }
    \\  FixedDate.prototype = NativeDate.prototype;
    \\  FixedDate.prototype.constructor = FixedDate;
    \\  FixedDate.now = () => { time(); return epoch; };
    \\  FixedDate.parse = NativeDate.parse; FixedDate.UTC = NativeDate.UTC;
    \\  globalThis.Date = FixedDate;
    \\  let seed = 0x6d2b79f5;
    \\  Math.random = () => { random(); seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; return seed / 4294967296; };
    \\})();
;
