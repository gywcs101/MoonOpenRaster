import { request } from './core.js?v=acceptance-20261118-1';

// One worker owns the MoonBit document. A preview never commits an edit.
self.onmessage = ({ data: { id, query } }) => {
  try {
    const result = JSON.parse(request(JSON.stringify(query)));
    if (result.rgba) {
      const raw = atob(result.rgba);
      const pixels = Uint8ClampedArray.from(raw, char => char.charCodeAt(0));
      delete result.rgba;
      result.pixels = pixels;
      self.postMessage({ id, result }, [pixels.buffer]);
    } else {
      self.postMessage({ id, result });
      if (result.ok && result.tree && result.editable !== false) {
        // The UI can display the snapshot while its smaller drag cache is prepared.
        request('{"action":"warm-preview"}');
      }
    }
  } catch (error) {
    self.postMessage({ id, result: { ok: false, error: error.message } });
  }
};
