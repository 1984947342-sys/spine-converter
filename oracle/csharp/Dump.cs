using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;
using Spine;
using static Output;

class NoTextureLoader : TextureLoader {
	public void Load (AtlasPage page, string path) { }
	public void Unload (object texture) { }
}

/// Mirrors oracle/dump_c.c for 3.5 and 3.6 and oracle/dump.cpp for 3.7 to 4.2
/// Each Vxy is defined from runtime x.y on
static class Program {
	const float SampleRate = 30;
	const int ClipCells = 4;

	static void Names (string key, IEnumerable<string> names) {
		Write("\"" + key + "\":[");
		bool first = true;
		foreach (string name in names) {
			if (!first) Write(",");
			first = false;
			Str(name);
		}
		Write("]");
	}

	/// Skin bones start with 3.8
	static bool Active (Bone bone) {
#if V38
		return bone.Active;
#else
		return true;
#endif
	}

	static void Vertices (Slot slot, ref float[] buffer) {
		// inactive bones keep stale world transforms
		if (!Active(slot.Bone)) {
			Write("null");
			return;
		}
		Attachment attachment = slot.Attachment;
		int count = 0;
		if (attachment != null && attachment.GetType() == typeof(RegionAttachment)) {
			count = 8;
			if (buffer.Length < 10) buffer = new float[10];
#if V41
			((RegionAttachment)attachment).ComputeWorldVertices(slot, buffer, 0, 2);
#elif V36
			((RegionAttachment)attachment).ComputeWorldVertices(slot.Bone, buffer, 0, 2);
#else
			((RegionAttachment)attachment).ComputeWorldVertices(slot.Bone, buffer);
			// 3.6 starts at the bottom right corner
			Array.Copy(buffer, 0, buffer, 2, 8);
			buffer[0] = buffer[8];
			buffer[1] = buffer[9];
#endif
		} else if (attachment is VertexAttachment vertices) {
			count = vertices.WorldVerticesLength;
			if (buffer.Length < count) buffer = new float[count];
#if V36
			vertices.ComputeWorldVertices(slot, 0, count, buffer, 0, 2);
#else
			vertices.ComputeWorldVertices(slot, buffer);
#endif
		}
		Write("[");
		for (int i = 0; i < count; i++) {
			if (i > 0) Write(",");
			Float(buffer[i]);
		}
		Write("]");
	}

	/// Covered fraction of each cell of a grid over the clipping polygon bounds
	static void Clip (Slot slot) {
#if V36
		Attachment attachment = Active(slot.Bone) ? slot.Attachment : null;
		if (attachment == null || attachment.GetType() != typeof(ClippingAttachment)) {
			Write("null");
			return;
		}
		var clip = (ClippingAttachment)attachment;
		int n = clip.WorldVerticesLength;
		float[] world = new float[n];
		clip.ComputeWorldVertices(slot, 0, n, world, 0, 2);
		float minX = world[0], minY = world[1], maxX = world[0], maxY = world[1];
		for (int i = 2; i < n; i += 2) {
			minX = MathF.Min(minX, world[i]);
			maxX = MathF.Max(maxX, world[i]);
			minY = MathF.Min(minY, world[i + 1]);
			maxY = MathF.Max(maxY, world[i + 1]);
		}
		var clipper = new SkeletonClipping();
		if (clipper.ClipStart(slot, clip) == 0) {
			Write("[]");
			return;
		}
		float w = (maxX - minX) / ClipCells, h = (maxY - minY) / ClipCells;
		int[] triangles = { 0, 1, 2, 0, 2, 3 };
		Write("[");
		for (int cell = 0; cell < ClipCells * ClipCells; cell++) {
			float x = minX + w * (cell % ClipCells), y = minY + h * (cell / ClipCells);
			float[] quad = { x, y, x + w, y, x + w, y + h, x, y + h };
			float[] uvs = new float[8];
#if V42
			clipper.ClipTriangles(quad, triangles, 6, uvs);
#else
			clipper.ClipTriangles(quad, 8, triangles, 6, uvs);
#endif
			float[] v = clipper.ClippedVertices.Items;
			int[] t = clipper.ClippedTriangles.Items;
			float area = 0;
			for (int i = 0, tn = clipper.ClippedTriangles.Count; i < tn; i += 3) {
				float ax = v[t[i] * 2], ay = v[t[i] * 2 + 1];
				float bx = v[t[i + 1] * 2], by = v[t[i + 1] * 2 + 1];
				float cx = v[t[i + 2] * 2], cy = v[t[i + 2] * 2 + 1];
				area += MathF.Abs((bx - ax) * (cy - ay) - (cx - ax) * (by - ay)) / 2;
			}
			if (cell > 0) Write(",");
			Float(w * h > 0 ? area / (w * h) : 0);
		}
		Write("]");
		clipper.ClipEnd();
#else
		Write("null");
#endif
	}

	/// Audio events start with 3.7, older events print the 3.7 defaults
	static void Events (ExposedList<Event> events) {
		Write(",\"events\":[");
		for (int i = 0; i < events.Count; i++) {
			Event e = events.Items[i];
			if (i > 0) Write(",");
			Write("[");
			Str(e.Data.Name);
			Write(",");
			Int(e.Int);
			Write(",");
			Float(e.Float);
			Write(",");
			Str(e.String);
#if V37
			Write(",");
			Float(e.Volume);
			Write(",");
			Float(e.Balance);
			Write(",");
			Float(e.Time);
			Write(",");
			Str(e.Data.AudioPath);
#else
			Write(",1,0,");
			Float(e.Time);
			Write(",\"\"");
#endif
			Write("]");
		}
		Write("]");
	}

	static void Sample (Skeleton skeleton, string skin, string animation, float time, ExposedList<Event> events, ref float[] buffer) {
		Write("{\"skin\":");
		Str(skin);
		Write(",\"animation\":");
		Str(animation);
		Write(",\"time\":");
		Float(time);
		if (events != null) Events(events);

		Write(",\"bones\":[");
		ExposedList<Bone> bones = skeleton.Bones;
		for (int i = 0; i < bones.Count; i++) {
			Bone bone = bones.Items[i];
			if (i > 0) Write(",");
			if (!Active(bone)) {
				Write("null");
				continue;
			}
			float[] values = { bone.A, bone.B, bone.C, bone.D, bone.WorldX, bone.WorldY };
			Write("[");
			for (int v = 0; v < 6; v++) {
				if (v > 0) Write(",");
				Float(values[v]);
			}
			Write("]");
		}

		Write("],\"slots\":[");
		ExposedList<Slot> slots = skeleton.Slots;
		for (int i = 0; i < slots.Count; i++) {
			Slot slot = slots.Items[i];
			if (i > 0) Write(",");
			Write("{\"attachment\":");
			if (slot.Attachment != null)
				Str(slot.Attachment.Name);
			else
				Write("null");
			Write(",\"color\":[");
			Float(slot.R);
			Write(",");
			Float(slot.G);
			Write(",");
			Float(slot.B);
			Write(",");
			Float(slot.A);
			Write("],\"dark\":");
#if V36
			if (slot.HasSecondColor) {
				Write("[");
				Float(slot.R2);
				Write(",");
				Float(slot.G2);
				Write(",");
				Float(slot.B2);
				Write("]");
			} else
				Write("null");
#else
			Write("null");
#endif
#if V41
			if (slot.Attachment is IHasTextureRegion textured && textured.Sequence != null) {
				Sequence sequence = textured.Sequence;
				int index = slot.SequenceIndex == -1 ? sequence.SetupIndex : slot.SequenceIndex;
				Write(",\"sequence\":");
				Int(Math.Min(index, sequence.Regions.Length - 1));
			}
#endif
			Write(",\"vertices\":");
			Vertices(slot, ref buffer);
			Write(",\"clip\":");
			Clip(slot);
			Write("}");
		}

		Write("],\"drawOrder\":[");
		ExposedList<Slot> order = skeleton.DrawOrder;
		for (int i = 0; i < order.Count; i++) {
			if (i > 0) Write(",");
			Int(order.Items[i].Data.Index);
		}
		Write("]}\n");
	}

	// spine-cpp filters start at Unknown
	static int Filter (TextureFilter filter) {
		return (int)filter + 1;
	}

	static int PrintAtlas (Atlas atlas) {
		List<AtlasPage> pages = Pages(atlas);
		if (pages.Count == 0) {
			Console.Error.WriteLine("atlas has no pages");
			return 1;
		}
		foreach (AtlasPage page in pages) {
#if V40
			int pma = page.pma ? 1 : 0;
#else
			int pma = 0;
#endif
			Write("page\t");
			Str(page.name);
			Write("\t" + string.Join("\t", page.width, page.height, (int)page.format, Filter(page.minFilter), Filter(page.magFilter),
				(int)page.uWrap, (int)page.vWrap, pma) + "\n");
		}
		foreach (AtlasRegion region in Regions(atlas)) {
			Write("region\t");
			Int(pages.IndexOf(region.page));
			Write("\t");
			Str(region.name);
#if V41
			// 4.1 swaps the packed size of rotated regions
			bool swapped = region.degrees == 90;
			int width = swapped ? region.packedHeight : region.packedWidth;
			int height = swapped ? region.packedWidth : region.packedHeight;
#else
			int width = region.width, height = region.height;
#endif
			Write("\t" + string.Join("\t", region.x, region.y, width, height));
			foreach (float f in new[] { region.u, region.v, region.u2, region.v2, region.offsetX, region.offsetY }) {
				Write("\t");
				Float(f);
			}
#if V38
			int degrees = region.degrees;
#else
			int degrees = region.rotate ? 90 : 0;
#endif
			Write("\t" + string.Join("\t", region.originalWidth, region.originalHeight, degrees, region.index) + "\t");
#if V40
			if (region.names != null) Write(string.Join(",", region.names));
			Write("\t");
			bool first = true;
			if (region.values != null) {
				foreach (int[] entry in region.values) {
					foreach (int value in entry) {
						if (!first) Write(",");
						first = false;
						Float(value);
					}
				}
			}
#else
			// 4.x keeps split and pad as named values
			Write(region.splits != null ? (region.pads != null ? "split,pad" : "split") : "");
			Write("\t");
			var values = new List<int>();
			if (region.splits != null) values.AddRange(region.splits);
			if (region.pads != null) values.AddRange(region.pads);
			Write(string.Join(",", values));
#endif
			Write("\n");
		}
		return 0;
	}

	// Atlas lists are private before 3.8
	static List<AtlasPage> Pages (Atlas atlas) {
#if V38
		return atlas.Pages;
#else
		return (List<AtlasPage>)typeof(Atlas).GetField("pages", BindingFlags.NonPublic | BindingFlags.Instance).GetValue(atlas);
#endif
	}

	static List<AtlasRegion> Regions (Atlas atlas) {
#if V38
		return atlas.Regions;
#else
		return (List<AtlasRegion>)typeof(Atlas).GetField("regions", BindingFlags.NonPublic | BindingFlags.Instance).GetValue(atlas);
#endif
	}

	static SkeletonData Read (Atlas atlas, string path) {
		byte[] bytes = File.ReadAllBytes(path);
		if (path.Contains(".json")) {
			string text = new UTF8Encoding(false).GetString(bytes);
#if V38 && !V40
			// 3.8 runtimes reject 3.8.75 of the 3.8.99 layout
			text = new Regex("(\"spine\"\\s*:\\s*\")3\\.8\\.75\"").Replace(text, "${1}3.8.99\"", 1);
#endif
			return new SkeletonJson(atlas).ReadSkeletonData(new StringReader(text));
		}
#if V38 && !V40
		if (SkeletonBinary.GetVersionString(new MemoryStream(bytes)) == "3.8.75") {
			byte[] from = Encoding.ASCII.GetBytes("3.8.75");
			int at = bytes.AsSpan().IndexOf(from);
			Encoding.ASCII.GetBytes("3.8.99").CopyTo(bytes, at);
		}
#endif
		return new SkeletonBinary(atlas).ReadSkeletonData(new MemoryStream(bytes));
	}

	/// Negative delta restarts physics
	static void UpdateWorldTransform (Skeleton skeleton, float delta) {
#if V42
		if (Environment.GetEnvironmentVariable("ORACLE_PHYSICS") == null) {
			skeleton.UpdateWorldTransform(Skeleton.Physics.None);
			return;
		}
		if (delta < 0) foreach (PhysicsConstraint constraint in skeleton.PhysicsConstraints) constraint.Reset();
		skeleton.Update(delta < 0 ? 0 : delta);
		skeleton.UpdateWorldTransform(Skeleton.Physics.Update);
#else
		skeleton.UpdateWorldTransform();
#endif
	}

	static void Apply (Animation animation, Skeleton skeleton, float lastTime, float time, ExposedList<Event> events) {
#if V37
		animation.Apply(skeleton, lastTime, time, false, events, 1, MixBlend.Setup, MixDirection.In);
#elif V36
		animation.Apply(skeleton, lastTime, time, false, events, 1, MixPose.Setup, MixDirection.In);
#else
		animation.Apply(skeleton, lastTime, time, false, events, 1, true, false);
#endif
	}

	static int Main (string[] args) {
		try {
			return Run(args);
		} finally {
			Out.Flush();
		}
	}

	static int Run (string[] args) {
		var textureLoader = new NoTextureLoader();
		if (args.Length == 1) return PrintAtlas(new Atlas(args[0], textureLoader));
		if (args.Length != 2) {
			Console.Error.WriteLine("usage: Dump <skeleton.json|skeleton.skel> <atlas>");
			Console.Error.WriteLine("       Dump <atlas>");
			return 2;
		}
		Bone.yDown = false;

		SkeletonData data;
		try {
			data = Read(new Atlas(args[1], textureLoader), args[0]);
		} catch (Exception e) {
			Console.Error.WriteLine(e.Message);
			return 1;
		}

		var skeleton = new Skeleton(data);
		string flip = Environment.GetEnvironmentVariable("ORACLE_FLIP") ?? "";
#if V37
		if (flip.Contains("x")) skeleton.ScaleX = -1;
		if (flip.Contains("y")) skeleton.ScaleY = -1;
#else
		skeleton.FlipX = flip.Contains("x");
		skeleton.FlipY = flip.Contains("y");
#endif
		Write("{\"version\":");
		Str(data.Version);
		Write(",");
		Names("bones", Map(skeleton.Bones, b => b.Data.Name));
		Write(",");
		Names("slots", Map(skeleton.Slots, s => s.Data.Name));
		Write(",");
		Names("skins", Map(data.Skins, s => s.Name));
		Write("}\n");

		float[] buffer = new float[0];
		var events = new ExposedList<Event>();
		ExposedList<Skin> skins = data.Skins;
		ExposedList<Animation> animations = data.Animations;
		for (int s = 0; s == 0 || s < skins.Count; s++) {
			Skin skin = s < skins.Count ? skins.Items[s] : null;
			string skinName = skin != null ? skin.Name : "";
			skeleton.SetSkin(skin);
			skeleton.SetToSetupPose();
			UpdateWorldTransform(skeleton, -1);
			Sample(skeleton, skinName, "", 0, null, ref buffer);

			for (int a = 0; a < animations.Count; a++) {
				Animation animation = animations.Items[a];
				float duration = animation.Duration;
				// half frames avoid stepped keys on sample times
				for (int frame = -1; frame < 0 || (frame + 0.5f) / SampleRate < duration; frame++) {
					float time = frame < 0 ? 0 : (frame + 0.5f) / SampleRate;
					float delta = frame < 0 ? -1 : frame == 0 ? time : 1 / SampleRate;
					events.Clear();
					if (frame < 0) Apply(animation, skeleton, -1, duration, events);
					skeleton.SetToSetupPose();
					Apply(animation, skeleton, time, time, null);
					UpdateWorldTransform(skeleton, delta);
					Sample(skeleton, skinName, animation.Name, time, frame < 0 ? events : null, ref buffer);
				}
			}
		}
		return 0;
	}

	static IEnumerable<string> Map<T> (ExposedList<T> list, Func<T, string> name) {
		for (int i = 0; i < list.Count; i++) yield return name(list.Items[i]);
	}
}
