"""Align a tapcompare recording and report how the relay output differs from the source.

Usage: python3 Tools/TapCompare/compare.py <outdir>

Needs numpy and scipy. With Spatial Audio off, a transparent relay shows unity
gain, correlation 1.0 and a difference far below the signal; with Spatialize
Stereo on, the relay output is binaurally rendered and differs on purpose.
"""
import sys

import numpy as np
from scipy.signal import fftconvolve

SR = 48_000


def load(path):
    return np.fromfile(path, dtype="<f4").reshape(-1, 2).astype(np.float64)


def rms_db(x):
    return 20 * np.log10(np.sqrt(np.mean(x ** 2)) + 1e-30)


def band_power(signal, lo, hi, n=16_384):
    window = np.hanning(n)
    freqs = np.fft.rfftfreq(n, 1 / SR)
    spectra = [np.abs(np.fft.rfft(signal[i:i + n] * window)) ** 2 for i in range(0, len(signal) - n, n // 2)]
    power = np.mean(spectra, axis=0)
    return power[(freqs >= lo) & (freqs < hi)].sum()


def main():
    out = sys.argv[1]
    source, relay = load(f"{out}/source.f32"), load(f"{out}/relay.f32")

    # The relay lags its source by its buffering; find the lag on 15 s of audio.
    a = source[5 * SR:20 * SR].mean(axis=1)
    b = relay[5 * SR:20 * SR].mean(axis=1)
    corr = fftconvolve(b, a[::-1], "full")
    lag = int(np.argmax(corr)) - (len(a) - 1)
    if lag >= 0:
        x, y = source[: len(relay) - lag], relay[lag:]
    else:
        x, y = source[-lag:], relay[: len(source) + lag]
    n = min(len(x), len(y))
    x, y = x[:n], y[:n]
    diff = y - x

    identical = (x.astype("<f4").view("<u4") == y.astype("<f4").view("<u4")).mean()
    print(f"relay lag          {lag} frames ({lag / SR * 1000:.0f} ms)")
    print(f"level change       {rms_db(y) - rms_db(x):+.2f} dB")
    print(f"correlation L / R  {np.corrcoef(x[:, 0], y[:, 0])[0, 1]:.5f} / {np.corrcoef(x[:, 1], y[:, 1])[0, 1]:.5f}")
    print(f"difference / SNR   {rms_db(diff):.1f} dBFS / {rms_db(x) - rms_db(diff):.1f} dB")
    print(f"bit-identical      {identical * 100:.2f}% of samples")
    print("relay / source by band:")
    for lo, hi in [(20, 200), (200, 2_000), (2_000, 10_000), (10_000, 19_500), (19_500, 21_000), (21_000, 22_500)]:
        ratio = band_power(y[:, 0], lo, hi) / max(band_power(x[:, 0], lo, hi), 1e-30)
        print(f"  {lo:>6}-{hi:<6} Hz  {10 * np.log10(ratio):+7.2f} dB")


if __name__ == "__main__":
    main()
