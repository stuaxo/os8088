// =============================================================================
// tests/dosguest_v86.mjs - dosguest under v86, the emulator the website runs
//
//   node tests/dosguest_v86.mjs BOOT.img OS8088.img HDA.img MEM_TOP TICKS OUT.img
//
// BOOT.img   a DOS boot floppy whose autoexec runs `dg /k b:` and then echoes
//            DOSGUEST-BACK (tests/dosguest.py builds it)
// OS8088.img os8088's floppy, in B: - the kern_emu one (`make emu`), whose
//            VMMOUSE.DRV makes the pointer ABSOLUTE, so a click needs no homing
// HDA.img    C:, holding DG.COM; v86 writes into this buffer in place, and it
//            is written to OUT.img at the end so mtools can read DGRESULT.TXT
// MEM_TOP    the LINEAR address of os8088's `mem_top`, TICKS likewise
//            (tools/os88sym.py, for the emu kernel)
//
// What it checks, with no QMP and no screenshots (a node v86 has neither): the
// BDA's video mode becomes 12h and os8088's own mem_top is the HIDDEN size while
// it runs; Restart is clicked with a mouse-absolute event; DOS prints its marker
// back in text mode. The launcher's report is read from OUT.img by the caller.
// =============================================================================
import fs from "node:fs";
import path from "node:path";
import url from "node:url";

const dir = path.dirname(url.fileURLToPath(import.meta.url));
const V86DIR = process.env.V86_DIR || path.resolve(dir, "../../../v86");
const [, , bootImg, osImg, hdaPath, memTopS, ticksS, outPath] = process.argv;
const MEM_TOP = parseInt(memTopS), TICKS = parseInt(ticksS);
const { V86 } = await import(url.pathToFileURL(path.join(V86DIR, "build/libv86.mjs")).href);

// a DOM just big enough for the starter's MouseAdapter (os8088-smoke.mjs's shim)
const html = { nodeName: "HTML", parentNode: null };
const body = { nodeName: "BODY", parentNode: html, style: {} };
global.window = { addEventListener() {}, removeEventListener() {} };
global.document = { addEventListener() {}, removeEventListener() {}, body, pointerLockElement: null };

const hdaBytes = fs.readFileSync(hdaPath);
const hdaBuf = hdaBytes.buffer.slice(hdaBytes.byteOffset, hdaBytes.byteOffset + hdaBytes.byteLength);

const emulator = new V86({
    wasm_path: path.join(V86DIR, "build/v86.wasm"),
    bios: { url: path.join(V86DIR, "bios/seabios.bin") },
    vga_bios: { url: path.join(V86DIR, "bios/vgabios.bin") },
    fda: { url: bootImg },
    fdb: { url: osImg },
    hda: { buffer: hdaBuf },
    boot_order: 0x321,                 // v86: 1 = CD, 2 = hard disk, 3 = floppy, FIRST digit first
    memory_size: 32 * 1024 * 1024,
    vga_memory_size: 2 * 1024 * 1024,
    autostart: true,
});

const mem = (a, n) => emulator.read_memory(a, n);
const u8 = (a) => mem(a, 1)[0];
const u16 = (a) => { const b = mem(a, 2); return b[0] | (b[1] << 8); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const screen = () => {                  // the text screen, as one string. NOT read_memory:
    try {                               // v86's VGA serves B8000 through its own handlers, and
        return emulator.screen_adapter.get_text_screen().join("\n");   // the adapter is what has the text
    } catch (e) { return ""; }
};
const log = (...a) => console.log("[v86]", ...a);

const t0 = Date.now();
const elapsed = () => ((Date.now() - t0) / 1000).toFixed(0);
const result = { os8088_up: false, mem_top: 0, ticks_moved: false, back: false };

async function main() {
    // --- os8088 is up: graphics mode 12h in the BDA and a sane mem_top --------
    let up = false;
    while (Date.now() - t0 < 150000) {
        await sleep(500);
        const mt = u16(MEM_TOP);
        if (u8(0x449) === 0x12 && mt >= 0x8000 && mt <= 0xA000 && mt % 64 === 0) { result.mem_top = mt; up = true; break; }
    }
    result.os8088_up = up;
    log("os8088 up:", up, "mem_top=0x" + result.mem_top.toString(16), "after", elapsed(), "s");
    if (!up) {
        const rows = screen().split("\n");
        log("BDA video mode 0x" + u8(0x449).toString(16) + ", memory size " + u16(0x413) + " KB; screen:");
        rows.map((r) => r.trimEnd()).filter((r) => r).slice(0, 30).forEach((r) => log("  |" + r));
        return finish(1);
    }
    await sleep(4000);                  // let the desktop draw
    const k0 = u16(TICKS);
    await sleep(2000);
    result.ticks_moved = ((u16(TICKS) - k0) & 0xFFFF) > 10;

    // --- Restart: the System menu (the logo), then its item ---------------------
    const abs = (x, y) => emulator.bus.send("mouse-absolute", [x, y, 640, 480]);
    for (let i = 0; i < 3; i++) { abs(15, 9); await sleep(200); }
    emulator.bus.send("mouse-click", [true, false, false]);   // press on the logo
    await sleep(600);
    for (let i = 0; i < 3; i++) { abs(30, 108); await sleep(200); }
    emulator.bus.send("mouse-click", [false, false, false]);  // release over Restart
    log("clicked Restart");

    // --- DOS is back: its marker, in text -----------------------------------------
    while (Date.now() - t0 < 300000) {
        await sleep(1000);
        if (screen().includes("DOSGUEST-BACK")) { result.back = true; break; }
    }
    log("DOS back:", result.back, "after", elapsed(), "s");
    await sleep(1500);
    return finish(result.back ? 0 : 1);
}

function finish(code) {
    fs.writeFileSync(outPath, Buffer.from(hdaBuf));
    console.log("RESULT " + JSON.stringify(result));
    try { emulator.destroy?.(); } catch (e) {}
    process.exit(code);
}

main().catch((e) => { console.error(e); finish(2); });
