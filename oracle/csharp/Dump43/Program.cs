using System;
using System.Collections.Generic;
using Spine;
using static Output;

class NoTextureLoader : TextureLoader {
	public void Load (AtlasPage page, string path) { }
	public void Unload (object texture) { }
}

/// Mirrors oracle/dump_4.3.cpp
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

	static void Vertices (Skeleton skeleton, Slot slot, ref float[] buffer) {
		// inactive bones keep stale world transforms
		if (!slot.Bone.Active) {
			Write("null");
			return;
		}
		Attachment attachment = slot.AppliedPose.Attachment;
		int count = 0;
		if (attachment != null && attachment.GetType() == typeof(RegionAttachment)) {
			var region = (RegionAttachment)attachment;
			count = 8;
			if (buffer.Length < count) buffer = new float[count];
			region.ComputeWorldVertices(slot, region.GetOffsets(slot.AppliedPose), buffer, 0, 2);
		} else if (attachment is VertexAttachment vertices) {
			count = vertices.WorldVerticesLength;
			if (buffer.Length < count) buffer = new float[count];
			vertices.ComputeWorldVertices(skeleton, slot, 0, count, buffer, 0, 2);
		}
		Write("[");
		for (int i = 0; i < count; i++) {
			if (i > 0) Write(",");
			Float(buffer[i]);
		}
		Write("]");
	}

	/// Covered fraction of each cell of a grid over the clipping polygon bounds
	static void Clip (Skeleton skeleton, Slot slot) {
		Attachment attachment = null;
		if (slot.Bone.Active) attachment = slot.AppliedPose.Attachment;
		if (attachment == null || attachment.GetType() != typeof(ClippingAttachment)) {
			Write("null");
			return;
		}
		var clip = (ClippingAttachment)attachment;
		int n = clip.WorldVerticesLength;
		float[] world = new float[n];
		clip.ComputeWorldVertices(skeleton, slot, 0, n, world, 0, 2);
		float minX = world[0], minY = world[1], maxX = world[0], maxY = world[1];
		for (int i = 2; i < n; i += 2) {
			minX = MathF.Min(minX, world[i]);
			maxX = MathF.Max(maxX, world[i]);
			minY = MathF.Min(minY, world[i + 1]);
			maxY = MathF.Max(maxY, world[i + 1]);
		}
		var clipper = new SkeletonClipping();
		if (clipper.ClipStart(skeleton, slot, clip) == 0) {
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
			clipper.ClipTriangles(quad, triangles, 6, uvs);
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
	}

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
			Write(",");
			Float(e.Volume);
			Write(",");
			Float(e.Balance);
			Write(",");
			Float(e.Time);
			Write(",");
			Str(e.Data.AudioPath);
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
			BonePose pose = bones.Items[i].AppliedPose;
			if (i > 0) Write(",");
			if (!bones.Items[i].Active) {
				Write("null");
				continue;
			}
			float[] values = { pose.A, pose.B, pose.C, pose.D, pose.WorldX, pose.WorldY };
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
			SlotPose pose = slots.Items[i].AppliedPose;
			if (i > 0) Write(",");
			Write("{\"attachment\":");
			if (pose.Attachment != null)
				Str(pose.Attachment.Name);
			else
				Write("null");
			Color32F color = pose.GetColor();
			Write(",\"color\":[");
			Float(color.r);
			Write(",");
			Float(color.g);
			Write(",");
			Float(color.b);
			Write(",");
			Float(color.a);
			Write("],\"dark\":");
			if (pose.HasDarkColor) {
				Color32F dark = pose.GetDarkColor().Value;
				Write("[");
				Float(dark.r);
				Write(",");
				Float(dark.g);
				Write(",");
				Float(dark.b);
				Write("]");
			} else
				Write("null");
			if (pose.Attachment is IHasSequence sequenced && sequenced.Sequence.Regions.Length > 1) {
				Write(",\"sequence\":");
				Int(sequenced.Sequence.ResolveIndex(pose));
			}
			Write(",\"vertices\":");
			Vertices(skeleton, slots.Items[i], ref buffer);
			Write(",\"clip\":");
			Clip(skeleton, slots.Items[i]);
			Write("}");
		}

		Write("],\"drawOrder\":[");
		ExposedList<Slot> order = skeleton.DrawOrder.AppliedPose;
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
		List<AtlasPage> pages = atlas.Pages;
		if (pages.Count == 0) {
			Console.Error.WriteLine("atlas has no pages");
			return 1;
		}
		foreach (AtlasPage page in pages) {
			Write("page\t");
			Str(page.name);
			Write("\t" + string.Join("\t", page.width, page.height, (int)page.format, Filter(page.minFilter), Filter(page.magFilter),
				(int)page.uWrap, (int)page.vWrap, page.pma ? 1 : 0) + "\n");
		}
		foreach (AtlasRegion region in atlas.Regions) {
			// 4.3 swaps the packed size of rotated regions
			bool swapped = region.degrees == 90;
			int width = swapped ? region.packedHeight : region.packedWidth;
			int height = swapped ? region.packedWidth : region.packedHeight;
			Write("region\t");
			Int(pages.IndexOf(region.page));
			Write("\t");
			Str(region.name);
			Write("\t" + string.Join("\t", region.x, region.y, width, height));
			foreach (float f in new[] { region.u, region.v, region.u2, region.v2, region.offsetX, region.offsetY }) {
				Write("\t");
				Float(f);
			}
			Write("\t" + string.Join("\t", region.originalWidth, region.originalHeight, region.degrees, region.index) + "\t");
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
			Write("\n");
		}
		return 0;
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
			Console.Error.WriteLine("usage: Dump43 <skeleton.json|skeleton.skel> <atlas>");
			Console.Error.WriteLine("       Dump43 <atlas>");
			return 2;
		}
		Bone.yDown = false;

		SkeletonData data;
		try {
			var atlas = new Atlas(args[1], textureLoader);
			SkeletonLoader loader = args[0].Contains(".json") ? new SkeletonJson(atlas) : new SkeletonBinary(atlas);
			data = loader.ReadSkeletonData(args[0]);
		} catch (Exception e) {
			Console.Error.WriteLine(e.Message);
			return 1;
		}

		var skeleton = new Skeleton(data);
		string flip = Environment.GetEnvironmentVariable("ORACLE_FLIP") ?? "";
		if (flip.Contains("x")) skeleton.ScaleX = -1;
		if (flip.Contains("y")) skeleton.ScaleY = -1;
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
			skeleton.SetupPose();
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
					if (frame < 0) animation.Apply(skeleton, -1, duration, false, events, 1, MixFrom.Setup, false, false, false);
					skeleton.SetupPose();
					animation.Apply(skeleton, time, time, false, null, 1, MixFrom.Setup, false, false, false);
					UpdateWorldTransform(skeleton, delta);
					Sample(skeleton, skinName, animation.Name, time, frame < 0 ? events : null, ref buffer);
				}
			}
		}
		return 0;
	}

	/// Negative delta restarts physics
	static void UpdateWorldTransform (Skeleton skeleton, float delta) {
		if (Environment.GetEnvironmentVariable("ORACLE_PHYSICS") == null) {
			skeleton.UpdateWorldTransform(Physics.None);
			return;
		}
		if (delta < 0) foreach (PhysicsConstraint constraint in skeleton.PhysicsConstraints) constraint.Reset(skeleton);
		skeleton.Update(delta < 0 ? 0 : delta);
		skeleton.UpdateWorldTransform(Physics.Update);
	}

	static IEnumerable<string> Map<T> (ExposedList<T> list, Func<T, string> name) {
		for (int i = 0; i < list.Count; i++) yield return name(list.Items[i]);
	}
}
