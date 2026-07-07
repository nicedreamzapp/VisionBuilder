#!/usr/bin/env ruby
# Adds new model files + Swift sources to the Vision Builder target.
# Idempotent — running twice produces no duplicates.

require 'xcodeproj'
require 'pathname'

ROOT = Pathname.new(File.expand_path('..', __dir__))
PROJECT_PATH = ROOT.join('Vision Builder.xcodeproj').to_s
TARGET_NAME = 'Vision Builder'

SWIFT_FILES = %w[
  SAM3ConceptService.swift
  FoundationModelsClusterNamer.swift
  PhotoDepthExtractor.swift
  LiveRecognitionView.swift
]

# .mlpackage are directories — added as folder references and bundled as resources.
ML_PACKAGES = %w[
  mobileclip2_s0_image.mlpackage
  mobileclip2_s0_text.mlpackage
  yolo26n.mlpackage
  yoloe11s_pf.mlpackage
]

RESOURCE_FILES = %w[
  yolo26_class_names.txt
  yoloe_classes.json
]

project = Xcodeproj::Project.open(PROJECT_PATH)
target = project.targets.find { |t| t.name == TARGET_NAME } or abort("Target #{TARGET_NAME} not found")

# Project root references live in the top-level main_group (alongside clip_vocab.json etc).
# The PBXFileSystemSynchronizedRootGroup ("Vision Builder" subdir) is for nested files only.
root_group = project.main_group

def file_ref_for(group, basename, source_root)
  source_root.children.detect { |c| c.is_a?(Xcodeproj::Project::Object::PBXFileReference) && c.path == basename }
end

added = []

# Helper: find existing reference at the project root by path.
def existing_ref(project, basename)
  project.files.detect { |f| f.path == basename }
end

SWIFT_FILES.each do |fname|
  if existing_ref(project, fname)
    puts "skip swift: #{fname} (already in project)"
    next
  end
  ref = root_group.new_reference(ROOT.join(fname).to_s)
  ref.set_source_tree('SOURCE_ROOT')
  ref.set_path(fname)
  target.source_build_phase.add_file_reference(ref, true)
  added << fname
  puts "added swift: #{fname}"
end

ML_PACKAGES.each do |pname|
  if existing_ref(project, pname)
    puts "skip mlpackage: #{pname} (already in project)"
    next
  end
  ref = root_group.new_reference(ROOT.join(pname).to_s)
  ref.last_known_file_type = 'wrapper.mlpackage'
  ref.set_source_tree('SOURCE_ROOT')
  ref.set_path(pname)
  target.resources_build_phase.add_file_reference(ref, true)
  added << pname
  puts "added mlpackage: #{pname}"
end

RESOURCE_FILES.each do |rname|
  if existing_ref(project, rname)
    puts "skip resource: #{rname} (already in project)"
    next
  end
  ref = root_group.new_reference(ROOT.join(rname).to_s)
  ref.set_source_tree('SOURCE_ROOT')
  ref.set_path(rname)
  target.resources_build_phase.add_file_reference(ref, true)
  added << rname
  puts "added resource: #{rname}"
end

project.save
puts "\nDone. #{added.size} file(s) added: #{added.join(', ')}"
