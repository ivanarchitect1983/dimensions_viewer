module DimViewer
  module Intersections

    TEMP_MATERIAL_NAME = 'DimViewer Intersection Red'.freeze
    TEMP_TAG_NAME = 'DimViewer Temporary Intersections'.freeze
    TEMP_VOLUME_NAME = 'DimViewer intersection volume'.freeze
    FADE_MATERIAL_NAME = 'DimViewer Fade'.freeze

    TRANSPARENT_ALPHA = 0.3

    @temp_intersection_volumes = []
    @overlay_edges = []
    @overlay_tool = nil

    # Хранилище для восстановления исходных материалов.
    # Формат для граней:    { entityID => { type: :face, face:, front:, back: } }
    # Формат для контейнеров:{ entityID => { type: :container, container:, material: } }
    @faded_entities = {}

    class IntersectionOverlayTool
      def initialize(edges_provider)
        @edges_provider = edges_provider
      end

      def activate
        Sketchup.active_model.active_view.invalidate
      rescue => e
        puts "DimViewer IntersectionOverlayTool activate error: #{e.message}"
      end

      def deactivate(view)
        view.invalidate if view
      rescue => e
        puts "DimViewer IntersectionOverlayTool deactivate error: #{e.message}"
      end

      def resume(view)
        view.invalidate if view
      rescue => e
        puts "DimViewer IntersectionOverlayTool resume error: #{e.message}"
      end

      def suspend(view)
        view.invalidate if view
      rescue => e
        puts "DimViewer IntersectionOverlayTool suspend error: #{e.message}"
      end

      def draw(view)
        edges = @edges_provider.call
        return if edges.nil? || edges.empty?

        view.line_width = 4
        view.line_stipple = ''
        view.drawing_color = Sketchup::Color.new(255, 0, 0, 255)

        edges.each do |edge_points|
          p1, p2 = edge_points
          next unless p1 && p2

          view.draw(GL_LINES, [p1, p2])
        end

        view.line_width = 1
      rescue => e
        puts "DimViewer IntersectionOverlayTool draw error: #{e.message}"
      end
    end

    def self.model
      Sketchup.active_model
    end

    def self.selection
      model.selection
    end

    def self.temp_intersection_volumes
      @temp_intersection_volumes ||= []
    end

    def self.overlay_edges
      @overlay_edges ||= []
    end

    def self.faded_entities
      @faded_entities ||= {}
    end

    def self.intersection_material
      materials = model.materials

      material = materials[TEMP_MATERIAL_NAME] || materials.add(TEMP_MATERIAL_NAME)
      material.color = Sketchup::Color.new(255, 0, 0)
      material.alpha = 1.0

      material
    end

    def self.intersection_tag
      layers = model.layers

      tag = layers[TEMP_TAG_NAME] || layers.add(TEMP_TAG_NAME)
      tag.visible = true

      tag
    end

    def self.set_entity_tag(entity, tag)
      return unless entity && entity.valid?

      if entity.respond_to?(:tag=)
        entity.tag = tag
      elsif entity.respond_to?(:layer=)
        entity.layer = tag
      end
    rescue => e
      puts "DimViewer set_entity_tag error: #{e.message}"
    end

    def self.paint_entity_recursive(entity, material)
      return unless entity && entity.valid?

      entity.material = material if entity.respond_to?(:material=)

      case entity
      when Sketchup::Group
        entity.entities.each do |child|
          paint_entity_recursive(child, material)
        end
      when Sketchup::ComponentInstance
        entity.definition.entities.each do |child|
          paint_entity_recursive(child, material)
        end
      when Sketchup::Face
        entity.material = material
        entity.back_material = material
      end
    rescue => e
      puts "DimViewer paint_entity_recursive error: #{e.message}"
    end

    def self.visible_intersection_candidates
      selection.grep(Sketchup::Group) + selection.grep(Sketchup::ComponentInstance)
    end

    def self.bounds_intersect?(a, b)
      return false unless a && b
      return false unless a.valid? && b.valid?

      ba = a.bounds
      bb = b.bounds

      return false if ba.max.x < bb.min.x
      return false if ba.min.x > bb.max.x

      return false if ba.max.y < bb.min.y
      return false if ba.min.y > bb.max.y

      return false if ba.max.z < bb.min.z
      return false if ba.min.z > bb.max.z

      true
    rescue => e
      puts "DimViewer bounds_intersect? error: #{e.message}"
      false
    end

    def self.solid_like?(entity)
      return false unless entity && entity.valid?

      if entity.respond_to?(:manifold?)
        return entity.manifold?
      end

      true
    rescue
      true
    end

    def self.copy_entity_to_active_entities(entity)
      return nil unless entity && entity.valid?

      entity.copy
    rescue => e
      puts "DimViewer copy_entity_to_active_entities error: #{e.message}"
      nil
    end

    def self.erase_entity(entity)
      entity.erase! if entity && entity.valid?
    rescue => e
      puts "DimViewer erase_entity error: #{e.message}"
    end

    def self.boolean_intersection_supported?(entity)
      entity && entity.valid? && entity.respond_to?(:intersect)
    end

    def self.create_intersection_volume(a, b)
      return nil unless a && b
      return nil unless a.valid? && b.valid?
      return nil unless bounds_intersect?(a, b)

      material = intersection_material
      tag = intersection_tag

      result = nil
      copy_a = nil
      copy_b = nil

      model.start_operation('DimViewer create intersection volume', true)

      begin
        copy_a = copy_entity_to_active_entities(a)
        copy_b = copy_entity_to_active_entities(b)

        unless copy_a && copy_b
          model.abort_operation
          return nil
        end

        copy_a.hidden = true if copy_a.respond_to?(:hidden=)
        copy_b.hidden = true if copy_b.respond_to?(:hidden=)

        unless boolean_intersection_supported?(copy_a)
          erase_entity(copy_a)
          erase_entity(copy_b)
          model.abort_operation
          return nil
        end

        result = copy_a.intersect(copy_b)

        erase_entity(copy_a)
        erase_entity(copy_b)

        unless result && result.valid?
          model.commit_operation
          return nil
        end

        result.name = TEMP_VOLUME_NAME if result.respond_to?(:name=)
        set_entity_tag(result, tag)
        paint_entity_recursive(result, material)

        result.hidden = false if result.respond_to?(:hidden=)
        result.casts_shadows = false if result.respond_to?(:casts_shadows=)
        result.receives_shadows = false if result.respond_to?(:receives_shadows=)

        temp_intersection_volumes << result

        model.commit_operation
      rescue => e
        model.abort_operation rescue nil

        erase_entity(copy_a)
        erase_entity(copy_b)

        puts "DimViewer create_intersection_volume error: #{e.message}"
        result = nil
      end

      refresh_overlay_edges
      start_overlay_tool if result && result.valid?

      result
    end

    def self.collect_world_edges(entity, transform = Geom::Transformation.new, edges = [])
      return edges unless entity && entity.valid?

      case entity
      when Sketchup::Group
        child_transform = transform * entity.transformation

        entity.entities.each do |child|
          collect_world_edges(child, child_transform, edges)
        end
      when Sketchup::ComponentInstance
        child_transform = transform * entity.transformation

        entity.definition.entities.each do |child|
          collect_world_edges(child, child_transform, edges)
        end
      when Sketchup::Edge
        p1 = entity.start.position.transform(transform)
        p2 = entity.end.position.transform(transform)

        edges << [p1, p2]
      end

      edges
    rescue => e
      puts "DimViewer collect_world_edges error: #{e.message}"
      edges
    end

    def self.refresh_overlay_edges
      overlay_edges.clear

      temp_intersection_volumes.each do |volume|
        next unless volume && volume.valid?

        collect_world_edges(volume, Geom::Transformation.new, overlay_edges)
      end

      model.active_view.invalidate
    rescue => e
      puts "DimViewer refresh_overlay_edges error: #{e.message}"
    end

    def self.start_overlay_tool
      @overlay_tool ||= IntersectionOverlayTool.new(
        lambda {
          DimViewer::Intersections.overlay_edges
        }
      )

      current_tool = model.tools.active_tool

      return if current_tool == @overlay_tool

      model.tools.push_tool(@overlay_tool)
      model.active_view.invalidate
    rescue => e
      puts "DimViewer start_overlay_tool error: #{e.message}"
    end

    def self.stop_overlay_tool
      return unless @overlay_tool

      begin
        model.tools.pop_tool
      rescue => e
        puts "DimViewer stop_overlay_tool pop_tool error: #{e.message}"
      end

      model.active_view.invalidate
    rescue => e
      puts "DimViewer stop_overlay_tool error: #{e.message}"
    end

    # === Полупрозрачность пересекающихся объектов ===

    # Одна общая полупрозрачная краска. Пересоздаётся каждый раз,
    # чтобы alpha гарантированно применился.
    def self.fade_material
      materials = model.materials

      old = materials[FADE_MATERIAL_NAME]
      materials.remove(old) if old && old.valid?

      mat = materials.add(FADE_MATERIAL_NAME)
      mat.color = Sketchup::Color.new(150, 150, 150)
      mat.alpha = TRANSPARENT_ALPHA
      mat.use_alpha = true if mat.respond_to?(:use_alpha=)

      mat
    end

    def self.remember_container(entity)
      cid = entity.entityID
      return if faded_entities.key?(cid)

      faded_entities[cid] = {
        type: :container,
        container: entity,
        material: (entity.respond_to?(:material) ? entity.material : nil)
      }
    rescue => e
      puts "DimViewer remember_container error: #{e.message}"
    end

    # Рекурсивно назначает полупрозрачный материал контейнерам и всем граням,
    # запоминая исходные материалы для восстановления.
    def self.fade_faces_recursive(entity, fade_mat)
      return unless entity && entity.valid?

      case entity
      when Sketchup::Group
        remember_container(entity)
        entity.material = fade_mat if entity.respond_to?(:material=)

        entity.entities.each do |child|
          fade_faces_recursive(child, fade_mat)
        end
      when Sketchup::ComponentInstance
        remember_container(entity)
        entity.material = fade_mat if entity.respond_to?(:material=)

        entity.definition.entities.each do |child|
          fade_faces_recursive(child, fade_mat)
        end
      when Sketchup::Face
        fid = entity.entityID

        unless faded_entities.key?(fid)
          faded_entities[fid] = {
            type: :face,
            face: entity,
            front: entity.material,
            back: entity.back_material
          }
        end

        entity.material = fade_mat
        entity.back_material = fade_mat
      end
    rescue => e
      puts "DimViewer fade_faces_recursive error: #{e.message}"
    end

    def self.restore_faded_entities
      faded_entities.each_value do |info|
        case info[:type]
        when :face
          face = info[:face]
          next unless face && face.valid?

          face.material = info[:front]
          face.back_material = info[:back]
        when :container
          cont = info[:container]
          next unless cont && cont.valid?

          cont.material = info[:material] if cont.respond_to?(:material=)
        end
      end

      faded_entities.clear

      mat = model.materials[FADE_MATERIAL_NAME]
      model.materials.remove(mat) if mat && mat.valid?
    rescue => e
      puts "DimViewer restore_faded_entities error: #{e.message}"
    end

    # Оставляет в выделении только пересекающиеся объекты
    # и делает их полупрозрачными.
    def self.apply_selection_and_fade(intersecting_list)
      sel = selection
      sel.clear

      return if intersecting_list.nil? || intersecting_list.empty?

      model.start_operation('DimViewer fade intersecting', true)

      begin
        fade_mat = fade_material

        intersecting_list.each do |entity|
          next unless entity && entity.valid?

          fade_faces_recursive(entity, fade_mat)
        end

        model.commit_operation
      rescue => e
        model.abort_operation rescue nil
        puts "DimViewer apply_selection_and_fade fade error: #{e.message}"
      end

      intersecting_list.each do |entity|
        sel.add(entity) if entity && entity.valid?
      end

      model.active_view.invalidate
    rescue => e
      puts "DimViewer apply_selection_and_fade error: #{e.message}"
    end

    # === Очистка ===

    def self.clear_intersection_volumes
      # Сначала возвращаем исходные материалы объектов.
      restore_faded_entities

      temp_intersection_volumes.each do |volume|
        erase_entity(volume)
      end

      temp_intersection_volumes.clear
      overlay_edges.clear

      stop_overlay_tool

      model.active_view.invalidate
    rescue => e
      puts "DimViewer clear_intersection_volumes error: #{e.message}"
    end

    def self.clear_highlight
      clear_intersection_volumes
    rescue => e
      puts "DimViewer clear_highlight error: #{e.message}"
    end

    def self.intersection_pairs_from_entities(entities)
      pairs = []

      entities.each_with_index do |a, index|
        entities[(index + 1)..-1].to_a.each do |b|
          next unless a && b
          next unless a.valid? && b.valid?
          next unless bounds_intersect?(a, b)

          pairs << [a, b]
        end
      end

      pairs
    rescue => e
      puts "DimViewer intersection_pairs_from_entities error: #{e.message}"
      pairs
    end

    def self.check_selection
      clear_intersection_volumes

      candidates = visible_intersection_candidates

      if candidates.length < 2
        UI.messagebox('Выберите минимум две группы или компонента для проверки пересечений.')
        return []
      end

      pairs = intersection_pairs_from_entities(candidates)
      found = []

      # Объекты, у которых реально нашлось пересечение.
      intersecting_entities = {}

      pairs.each do |a, b|
        volume = create_intersection_volume(a, b)

        next unless volume && volume.valid?

        found << {
          first: a,
          second: b,
          volume: volume
        }

        intersecting_entities[a.entityID] = a if a.respond_to?(:entityID)
        intersecting_entities[b.entityID] = b if b.respond_to?(:entityID)
      end

      refresh_overlay_edges
      start_overlay_tool unless found.empty?

      # Обновляем выделение и прозрачность.
      apply_selection_and_fade(intersecting_entities.values)

      found
    rescue => e
      puts "DimViewer check_selection error: #{e.message}"
      []
    end

    def self.run
      check_selection
    end

  end
end