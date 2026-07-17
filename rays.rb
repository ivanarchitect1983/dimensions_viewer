module DimViewer
  module Rays

    GAP_UNIT = 25.4
    MAX_RAY_MM = 100_000.0

    LOCAL_DIRS = [
      [:xp, 0, +1], [:xn, 0, -1],
      [:yp, 1, +1], [:yn, 1, -1],
      [:zp, 2, +1], [:zn, 2, -1]
    ]

    DIR_LABELS = {
      xp: '-> X (право)', xn: '<- X (лево)',
      yp: '-> Y (вперёд)', yn: '<- Y (назад)',
      zp: '^ Z (верх)', zn: 'v Z (низ)'
    }

    @preview_tool = nil
    @walls = []

    class << self
      attr_reader :walls
    end

    def self.group_or_component?(entity)
      entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
    end

    def self.entities_of(entity)
      entity.is_a?(Sketchup::Group) ? entity.entities : entity.definition.entities
    end

    def self.ray_origin_dir(entity, box, dir_key)
      t = entity.transformation
      min, max = box

      axes = [
        t.xaxis.normalize,
        t.yaxis.normalize,
        t.zaxis.normalize
      ]

      c = [
        (min[0] + max[0]) / 2.0,
        (min[1] + max[1]) / 2.0,
        (min[2] + max[2]) / 2.0
      ]

      _, axis_i, sign = LOCAL_DIRS.find { |k, _, _| k == dir_key }

      local_start = c.dup
      local_start[axis_i] = sign > 0 ? max[axis_i] : min[axis_i]

      origin = Geom::Point3d.new(*local_start).transform(t)

      dir = axes[axis_i].clone
      dir = dir.reverse if sign < 0

      [origin, dir, axis_i, sign]
    end

    def self.face_rays(entity, box, dir_key)
      t = entity.transformation
      min, max = box

      axes = [
        t.xaxis.normalize,
        t.yaxis.normalize,
        t.zaxis.normalize
      ]

      _, axis_i, sign = LOCAL_DIRS.find { |k, _, _| k == dir_key }

      other = [0, 1, 2] - [axis_i]
      u_i, v_i = other

      plane_val = sign > 0 ? max[axis_i] : min[axis_i]

      us = [
        min[u_i],
        (min[u_i] + max[u_i]) / 2.0,
        max[u_i]
      ]

      vs = [
        min[v_i],
        (min[v_i] + max[v_i]) / 2.0,
        max[v_i]
      ]

      dir = axes[axis_i].clone
      dir = dir.reverse if sign < 0

      rays = []

      us.each do |uu|
        vs.each do |vv|
          local = [0.0, 0.0, 0.0]
          local[axis_i] = plane_val
          local[u_i] = uu
          local[v_i] = vv

          origin = Geom::Point3d.new(*local).transform(t)

          rays << [origin, dir]
        end
      end

      rays
    rescue => e
      puts "DimViewer Rays.face_rays error: #{e.message}"
      []
    end

    def self.self_entities(entity)
      set = {}
      set[entity.entityID] = true if entity.respond_to?(:entityID)

      entities_of(entity).each do |e|
        set[e.entityID] = true if e.respond_to?(:entityID)
      end

      set
    rescue
      {}
    end

    def self.target_entities(entity)
      set = {}
      set[entity.entityID] = true if entity.respond_to?(:entityID)

      entities_of(entity).each do |e|
        set[e.entityID] = true if e.respond_to?(:entityID)
      end

      set
    rescue
      {}
    end

    def self.set_walls_from_selection
      model = Sketchup.active_model
      return unless model

      ids = []

      model.selection.each do |e|
        next unless e.respond_to?(:entityID)
        next unless e.is_a?(Sketchup::Group) ||
                    e.is_a?(Sketchup::ComponentInstance) ||
                    e.is_a?(Sketchup::Face)

        ids << e.entityID
      end

      @walls = ids.uniq

      DimViewer::Main.update
      DimViewer::Main.notify_walls_state
    end

    def self.clear_walls
      @walls = []

      DimViewer::Main.update
      DimViewer::Main.notify_walls_state
    end

    def self.walls_count
      @walls.length
    end

    def self.path_is_wall?(path)
      return true if @walls.empty?
      return false unless path

      path.any? do |e|
        e.respond_to?(:entityID) && @walls.include?(e.entityID)
      end
    end

    def self.wall_raytest(model, origin, dir, selfset)
      dir = dir.normalize
      pt = origin

      max_len_in = MAX_RAY_MM / GAP_UNIT
      skip_offset = 0.02

      100.times do
        hit = model.raytest([pt, dir], false)
        return nil unless hit

        hit_pt, path = hit

        return nil if origin.distance(hit_pt) > max_len_in

        if path && path.any? { |e| e.respond_to?(:entityID) && selfset[e.entityID] }
          pt = hit_pt.offset(dir, skip_offset)
          next
        end

        if !@walls.empty? && !path_is_wall?(path)
          pt = hit_pt.offset(dir, skip_offset)
          next
        end

        return [hit_pt, path]
      end

      nil
    rescue => e
      puts "DimViewer Rays.wall_raytest error: #{e.message}"
      nil
    end

    def self.ray_to_target(model, origin, dir, selfset, target_ids)
      dir = dir.normalize
      pt = origin

      max_len_in = MAX_RAY_MM / GAP_UNIT
      skip_offset = 0.02

      100.times do
        hit = model.raytest([pt, dir], false)
        return nil unless hit

        hit_pt, path = hit

        return nil if origin.distance(hit_pt) > max_len_in

        if path && path.any? { |e| e.respond_to?(:entityID) && selfset[e.entityID] }
          pt = hit_pt.offset(dir, skip_offset)
          next
        end

        if path && path.any? { |e| e.respond_to?(:entityID) && target_ids[e.entityID] }
          return [hit_pt, path]
        end

        return nil
      end

      nil
    rescue => e
      puts "DimViewer Rays.ray_to_target error: #{e.message}"
      nil
    end

    def self.compute_gaps(entity)
      return nil unless group_or_component?(entity)

      box = DimViewer::Main.local_box(entity)
      return nil unless box

      model = Sketchup.active_model
      selfset = self_entities(entity)

      gaps = {}

      LOCAL_DIRS.each do |key, _, _|
        origin, dir, = ray_origin_dir(entity, box, key)
        origin_s = origin.offset(dir, 0.001)

        hit = wall_raytest(model, origin_s, dir, selfset)

        if hit
          hit_pt, = hit
          gaps[key] = origin_s.distance(hit_pt) * GAP_UNIT
        else
          gaps[key] = nil
        end
      end

      gaps
    rescue => e
      puts "DimViewer Rays.compute_gaps error: #{e.message}"
      nil
    end

    def self.pair_gaps(entity_a, entity_b)
      return nil unless group_or_component?(entity_a)
      return nil unless group_or_component?(entity_b)

      box = DimViewer::Main.local_box(entity_a)
      return nil unless box

      model = Sketchup.active_model

      selfset_a = self_entities(entity_a)
      target_ids = target_entities(entity_b)

      result = {}

      LOCAL_DIRS.each do |key, _, _|
        best = nil

        face_rays(entity_a, box, key).each do |origin, dir|
          origin_s = origin.offset(dir, 0.001)

          hit = ray_to_target(model, origin_s, dir, selfset_a, target_ids)
          next unless hit

          hit_pt = hit[0]
          d_mm = origin_s.distance(hit_pt) * GAP_UNIT

          best = d_mm if best.nil? || d_mm < best
        end

        result[key] = best
      end

      result
    rescue => e
      puts "DimViewer Rays.pair_gaps error: #{e.message}"
      nil
    end

    def self.pair_ray_hits(entity_a, entity_b)
      return [] unless group_or_component?(entity_a)
      return [] unless group_or_component?(entity_b)

      box = DimViewer::Main.local_box(entity_a)
      return [] unless box

      model = Sketchup.active_model

      selfset_a = self_entities(entity_a)
      target_ids = target_entities(entity_b)

      results = []

      LOCAL_DIRS.each do |key, axis_i, _|
        best = nil

        face_rays(entity_a, box, key).each do |origin, dir|
          origin_s = origin.offset(dir, 0.001)

          hit = ray_to_target(model, origin_s, dir, selfset_a, target_ids)
          next unless hit

          hit_pt = hit[0]
          d_mm = origin_s.distance(hit_pt) * GAP_UNIT

          best = [d_mm, origin_s, hit_pt] if best.nil? || d_mm < best[0]
        end

        if best
          results << {
            dir: key,
            dist: best[0],
            origin: best[1],
            hit: best[2],
            axis_i: axis_i
          }
        end
      end

      results
    rescue => e
      puts "DimViewer Rays.pair_ray_hits error: #{e.message}"
      []
    end

    def self.obstacle_name(entity)
      if entity.is_a?(Sketchup::Group)
        n = entity.name.to_s.strip
        n.empty? ? 'Группа' : n
      elsif entity.is_a?(Sketchup::ComponentInstance)
        n = entity.name.to_s.strip
        return n unless n.empty?

        entity.definition.name
      else
        'Объект'
      end
    rescue
      'Объект'
    end

    def self.apply_gap(dir_key, target_mm)
      model = Sketchup.active_model
      return unless model

      sel = model.selection
      return unless sel.length == 1

      entity = sel.first
      return unless group_or_component?(entity)

      box = DimViewer::Main.local_box(entity)
      return unless box

      origin, dir, = ray_origin_dir(entity, box, dir_key)
      origin_s = origin.offset(dir, 0.001)

      selfset = self_entities(entity)

      hit = wall_raytest(model, origin_s, dir, selfset)
      return unless hit

      hit_pt, path = hit

      current_gap = origin_s.distance(hit_pt) * GAP_UNIT
      delta_mm = current_gap - target_mm

      return if delta_mm.abs < 0.01

      if delta_mm > 0
        obstacle = nil

        if path
          obstacle = path.reverse.find do |e|
            (e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)) &&
              e.respond_to?(:entityID) &&
              !selfset[e.entityID]
          end
        end

        if obstacle
          name = obstacle_name(obstacle)

          res = UI.messagebox(
            "На пути объект: \"#{name}\".\n\n" \
            "Да - учесть, двигать вплотную к нему.\n" \
            "Нет - игнорировать, двигать сквозь на заданный зазор.\n" \
            "Отмена - не двигать.",
            MB_YESNOCANCEL
          )

          return if res == IDCANCEL
        end
      end

      delta_internal = delta_mm / GAP_UNIT

      move_vec = dir.clone
      move_vec.length = delta_internal

      model.start_operation('Задать зазор', true)
      entity.transform!(Geom::Transformation.translation(move_vec))
      model.commit_operation

      DimViewer::Main.update
    rescue => e
      puts "DimViewer Rays.apply_gap error: #{e.message}"
      begin
        model.abort_operation
      rescue
      end
    end

    def self.preview_active?
      !@preview_tool.nil?
    end

    def self.toggle_preview
      model = Sketchup.active_model
      return unless model

      if preview_active?
        model.select_tool(nil)
      else
        @preview_tool = PreviewTool.new
        model.select_tool(@preview_tool)
      end

      DimViewer::Main.notify_preview_state
    end

    def self.on_preview_deactivate
      @preview_tool = nil
      DimViewer::Main.notify_preview_state
    end

    def self.refresh_preview
      return unless preview_active?

      Sketchup.active_model.active_view.invalidate rescue nil
    end

    class PreviewTool

      AXIS_COLORS = {
        0 => Sketchup::Color.new(231, 76, 60),
        1 => Sketchup::Color.new(46, 204, 113),
        2 => Sketchup::Color.new(52, 152, 219)
      }

      HOVER_COLOR = Sketchup::Color.new(241, 196, 15)

      def activate
        @model = Sketchup.active_model
        @rays = []
        @hover = nil
        @mx = @my = 0

        @model.active_view.invalidate
      end

      def deactivate(view)
        view.invalidate
        DimViewer::Rays.on_preview_deactivate
      end

      def resume(view)
        view.invalidate
      end

      def suspend(_view)
      end

      def onCancel(_reason, _view)
        @model.select_tool(nil)
      end

      def dist_to_segment(px, py, ax, ay, bx, by)
        dx = bx - ax
        dy = by - ay

        len2 = dx * dx + dy * dy

        return Math.sqrt((px - ax)**2 + (py - ay)**2) if len2 < 1e-6

        t = ((px - ax) * dx + (py - ay) * dy) / len2
        t = 0.0 if t < 0.0
        t = 1.0 if t > 1.0

        cx = ax + t * dx
        cy = ay + t * dy

        Math.sqrt((px - cx)**2 + (py - cy)**2)
      end

      def ray_at(x, y)
        best = nil
        best_d = 8.0

        @rays.each do |r|
          d = dist_to_segment(x, y, r[:a].x, r[:a].y, r[:b].x, r[:b].y)

          if d < best_d
            best_d = d
            best = r
          end
        end

        best
      end

      def onMouseMove(_flags, x, y, view)
        @mx = x
        @my = y

        r = ray_at(x, y)
        new_hover = r ? r[:dir] : nil

        if new_hover != @hover
          @hover = new_hover
          view.invalidate
        end

        view.tooltip = @hover ? 'Клик - задать расстояние луча' : ''
      end

      def onLButtonDown(flags, x, y, view)
        r = ray_at(x, y)

        if r
          edit_gap(r[:dir], r[:dist])
          return
        end

        ph = view.pick_helper
        ph.do_pick(x, y)

        best = ph.best_picked
        sel = @model.selection

        add_mode = (flags & CONSTRAIN_MODIFIER_MASK != 0) ||
                   (flags & COPY_MODIFIER_MASK != 0)

        if best
          top = nil

          ph.count.times do |i|
            path = ph.path_at(i)

            if path
              g = path.reverse.find do |e|
                e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
              end

              top = g if g
              break if top
            end
          end

          top ||= best

          if add_mode
            if sel.include?(top)
              sel.remove(top)
            else
              sel.add(top)
            end
          else
            sel.clear
            sel.add(top)
          end
        else
          sel.clear unless add_mode
        end

        view.invalidate
      end

      def edit_gap(dir_key, current_mm)
        prompts = [
          "Расстояние (#{DimViewer::Rays::DIR_LABELS[dir_key]}), мм [можно 1200-18]:"
        ]

        defaults = [current_mm.round(1).to_s]

        res = UI.inputbox(prompts, defaults, 'Задать расстояние')
        return unless res

        v = DimViewer::Main.parse_arithmetic(res[0])
        return if v.nil? || v < 0

        DimViewer::Rays.apply_gap(dir_key, v)

        @model.active_view.invalidate
      end

      def onSetCursor
        UI.set_cursor(@hover ? 641 : 0)
      end

      def draw(view)
        @rays = []

        sel = @model.selection

        if sel.length == 1
          draw_single(view, sel.first)
        elsif sel.length == 2
          draw_pair(view, sel[0], sel[1])
        end
      rescue => e
        puts "DimViewer Rays::PreviewTool.draw error: #{e.message}"
      end

      def draw_single(view, entity)
        return unless DimViewer::Rays.group_or_component?(entity)

        box = DimViewer::Main.local_box(entity)
        return unless box

        selfset = DimViewer::Rays.self_entities(entity)

        DimViewer::Rays::LOCAL_DIRS.each do |key, _, _|
          origin, dir, ai, = DimViewer::Rays.ray_origin_dir(entity, box, key)
          origin_s = origin.offset(dir, 0.001)

          hit = DimViewer::Rays.wall_raytest(@model, origin_s, dir, selfset)
          next unless hit

          hit_pt, = hit

          dist_mm = origin_s.distance(hit_pt) * DimViewer::Rays::GAP_UNIT
          next if dist_mm > DimViewer::Rays::MAX_RAY_MM
          next if dist_mm < 0.01

          base_color = AXIS_COLORS[ai] || Sketchup::Color.new(255, 255, 255)

          hovered = @hover == key
          color = hovered ? HOVER_COLOR : base_color

          view.line_width = hovered ? 5 : 3
          view.line_stipple = ''
          view.drawing_color = color
          view.draw(GL_LINES, [origin, hit_pt])
          view.draw_points([origin, hit_pt], 6, 1, color)

          mid = Geom::Point3d.new(
            (origin.x + hit_pt.x) / 2.0,
            (origin.y + hit_pt.y) / 2.0,
            (origin.z + hit_pt.z) / 2.0
          )

          screen = view.screen_coords(mid)
          label = "#{dist_mm.round(1)} мм"

          draw_text_with_bg(view, screen, label, hovered ? HOVER_COLOR : color)

          @rays << {
            dir: key,
            dist: dist_mm,
            a: view.screen_coords(origin),
            b: view.screen_coords(hit_pt)
          }
        end
      end

      def draw_pair(view, a, b)
        return unless DimViewer::Rays.group_or_component?(a)
        return unless DimViewer::Rays.group_or_component?(b)

        hits = DimViewer::Rays.pair_ray_hits(a, b)
        return if hits.empty?

        hits.each do |h|
          origin = h[:origin]
          hit_pt = h[:hit]
          dist_mm = h[:dist]
          ai = h[:axis_i]

          next if dist_mm < 0.01

          base_color = AXIS_COLORS[ai] || Sketchup::Color.new(255, 255, 255)

          view.line_width = 3
          view.line_stipple = '-'
          view.drawing_color = base_color
          view.draw(GL_LINES, [origin, hit_pt])

          view.line_stipple = ''
          view.draw_points([origin, hit_pt], 7, 4, base_color)

          mid = Geom::Point3d.new(
            (origin.x + hit_pt.x) / 2.0,
            (origin.y + hit_pt.y) / 2.0,
            (origin.z + hit_pt.z) / 2.0
          )

          screen = view.screen_coords(mid)
          label = "#{dist_mm.round(1)} мм"

          draw_text_with_bg(view, screen, label, base_color)
        end
      end

      def draw_text_with_bg(view, pt, text, color)
        opts_shadow = {
          size: 12,
          bold: true,
          color: Sketchup::Color.new(0, 0, 0)
        }

        [[-1, -1], [1, -1], [-1, 1], [1, 1]].each do |dx, dy|
          p2 = Geom::Point3d.new(pt.x + dx, pt.y + dy, 0)
          view.draw_text(p2, text, opts_shadow) rescue view.draw_text(p2, text)
        end

        begin
          view.draw_text(pt, text, size: 12, bold: true, color: color)
        rescue
          view.draw_text(pt, text)
        end
      end

    end

  end
end