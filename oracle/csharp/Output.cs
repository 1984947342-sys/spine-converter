using System;
using System.Globalization;
using System.IO;
using System.Numerics;
using System.Text;

/// Mirrors the printf calls of oracle/dump.cpp
static class Output {
	public static readonly TextWriter Out = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false), 1 << 16) { NewLine = "\n" };

	public static void Write (string text) {
		Out.Write(text);
	}

	public static void Int (int value) {
		Out.Write(value.ToString(CultureInfo.InvariantCulture));
	}

	public static void Float (float value) {
		Out.Write(float.IsFinite(value) ? G9(value) : "null");
	}

	public static void Str (string value) {
		Out.Write('"');
		// null is the empty spine String
		foreach (char c in value ?? "") {
			if (c == '"' || c == '\\') {
				Out.Write('\\');
				Out.Write(c);
			} else if (c < 0x20)
				Out.Write("\\u" + ((int)c).ToString("x4", CultureInfo.InvariantCulture));
			else
				Out.Write(c);
		}
		Out.Write('"');
	}

	/// printf %.9g rounded half to even like glibc
	public static string G9 (double value) {
		const int precision = 9;
		if (value == 0) return double.IsNegative(value) ? "-0" : "0";
		string sign = value < 0 ? "-" : "";
		long bits = BitConverter.DoubleToInt64Bits(Math.Abs(value));
		int exponent = (int)((bits >> 52) & 0x7ff);
		long mantissa = bits & 0xfffffffffffffL;
		if (exponent == 0)
			exponent = 1;
		else
			mantissa |= 1L << 52;
		exponent -= 1075;
		BigInteger num = mantissa, den = BigInteger.One;
		if (exponent > 0)
			num <<= exponent;
		else
			den <<= -exponent;

		int point = (int)Math.Floor(Math.Log10(Math.Abs(value)));
		while (num * Pow10(-point) < den * Pow10(point) ) point--;
		while (num * Pow10(-point - 1) >= den * Pow10(point + 1)) point++;

		int shift = precision - 1 - point;
		BigInteger scaledNum = num * Pow10(shift), scaledDen = den * Pow10(-shift);
		BigInteger digits = BigInteger.DivRem(scaledNum, scaledDen, out BigInteger remainder);
		int half = (remainder * 2).CompareTo(scaledDen);
		if (half > 0 || (half == 0 && !digits.IsEven)) digits++;
		if (digits == Pow10(precision)) {
			digits = Pow10(precision - 1);
			point++;
		}
		string text = digits.ToString(CultureInfo.InvariantCulture);

		if (point < -4 || point >= precision) {
			string fraction = text.Substring(1).TrimEnd('0');
			return sign + text[0] + (fraction.Length > 0 ? "." + fraction : "") + "e" + (point < 0 ? "-" : "+")
				+ Math.Abs(point).ToString("00", CultureInfo.InvariantCulture);
		}
		string whole, rest;
		if (point >= 0) {
			whole = text.Substring(0, point + 1);
			rest = text.Substring(point + 1);
		} else {
			whole = "0";
			rest = new string('0', -point - 1) + text;
		}
		rest = rest.TrimEnd('0');
		return sign + whole + (rest.Length > 0 ? "." + rest : "");
	}

	/// One for n below one
	static BigInteger Pow10 (int n) {
		return n > 0 ? BigInteger.Pow(10, n) : BigInteger.One;
	}
}
