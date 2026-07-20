import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:math' as math;

Future<Map<String, int>> computePaletteFromBytes(Uint8List bytes) async {
	try {
		final codec = await ui.instantiateImageCodec(bytes, targetWidth: 48);
		final frame = await codec.getNextFrame();
		final image = frame.image;
		final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
		image.dispose();
		if (byteData == null) {
			return {
				'primary': 0xFF222222,
				'secondary': 0xFF444444,
				'tertiary': 0xFF666666,
			};
		}

		final rgbaBytes = byteData.buffer.asUint8List();
		final sampleStep = rgbaBytes.length > 14000 ? 16 : 8;
		final buckets = <int, ({int count, int rSum, int gSum, int bSum, int satSum})>{};

		for (var index = 0; index + 3 < rgbaBytes.length; index += sampleStep) {
			final r = rgbaBytes[index];
			final g = rgbaBytes[index + 1];
			final b = rgbaBytes[index + 2];
			final a = rgbaBytes[index + 3];
			if (a < 28) continue;

			final rBin = r ~/ 43;
			final gBin = g ~/ 43;
			final bBin = b ~/ 43;
			final key = (rBin << 16) | (gBin << 8) | bBin;

			final maxChannel = math.max(r, math.max(g, b));
			final minChannel = math.min(r, math.min(g, b));
			final sat = maxChannel - minChannel;

			final current = buckets[key];
			if (current == null) {
				buckets[key] = (count: 1, rSum: r, gSum: g, bSum: b, satSum: sat);
			} else {
				buckets[key] = (
					count: current.count + 1,
					rSum: current.rSum + r,
					gSum: current.gSum + g,
					bSum: current.bSum + b,
					satSum: current.satSum + sat,
				);
			}
		}

		if (buckets.isEmpty) {
			return {
				'primary': 0xFF222222,
				'secondary': 0xFF444444,
				'tertiary': 0xFF666666,
			};
		}

		int toArgbInt(int r, int g, int b) =>
				0xFF000000 | (r << 16) | (g << 8) | b;

		double colorDistanceSq(int c1, int c2) {
			final r1 = (c1 >> 16) & 0xFF;
			final g1 = (c1 >> 8) & 0xFF;
			final b1 = c1 & 0xFF;
			final r2 = (c2 >> 16) & 0xFF;
			final g2 = (c2 >> 8) & 0xFF;
			final b2 = c2 & 0xFF;
			final dr = (r1 - r2).toDouble();
			final dg = (g1 - g2).toDouble();
			final db = (b1 - b2).toDouble();
			return (dr * dr) + (dg * dg) + (db * db);
		}

		int mixToward(int color, int toward, double amount) {
			final r1 = (color >> 16) & 0xFF;
			final g1 = (color >> 8) & 0xFF;
			final b1 = color & 0xFF;
			final r2 = (toward >> 16) & 0xFF;
			final g2 = (toward >> 8) & 0xFF;
			final b2 = toward & 0xFF;
			final r = (r1 + ((r2 - r1) * amount)).round().clamp(0, 255);
			final g = (g1 + ((g2 - g1) * amount)).round().clamp(0, 255);
			final b = (b1 + ((b2 - b1) * amount)).round().clamp(0, 255);
			return toArgbInt(r, g, b);
		}

		final candidates = buckets.values.map((bucket) {
			final avgR = (bucket.rSum / bucket.count).round().clamp(0, 255);
			final avgG = (bucket.gSum / bucket.count).round().clamp(0, 255);
			final avgB = (bucket.bSum / bucket.count).round().clamp(0, 255);
			final satAvg = bucket.satSum / bucket.count;
			final lum = (0.299 * avgR) + (0.587 * avgG) + (0.114 * avgB);
			final midLumWeight = 1.0 - ((lum - 128).abs() / 220.0).clamp(0.0, 0.5);
			final score = bucket.count * (0.65 + (satAvg / 255.0) * 1.05) * midLumWeight;
			return (
				color: toArgbInt(avgR, avgG, avgB),
				score: score,
			);
		}).toList();

		candidates.sort((a, b) => b.score.compareTo(a.score));

		final selected = <int>[];
		for (final candidate in candidates) {
			final color = candidate.color;
			if (selected.isEmpty) {
				selected.add(color);
				continue;
			}
			final distinctEnough = selected.every(
				(existing) => colorDistanceSq(color, existing) > 40 * 40,
			);
			if (distinctEnough) {
				selected.add(color);
				if (selected.length == 3) break;
			}
		}

		while (selected.length < 3) {
			if (selected.isEmpty) {
				selected.add(0xFF303030);
			} else if (selected.length == 1) {
				selected.add(mixToward(selected.first, 0xFFFFFFFF, 0.32));
			} else {
				selected.add(mixToward(selected.first, 0xFF000000, 0.25));
			}
		}

		return {
			'primary': selected[0],
			'secondary': selected[1],
			'tertiary': selected[2],
		};
	} catch (_) {
		return {
			'primary': 0xFF222222,
			'secondary': 0xFF444444,
			'tertiary': 0xFF666666,
		};
	}
}
