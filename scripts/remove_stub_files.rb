#!/usr/bin/env ruby
# Removes stub files from the Xcode project + deletes them from disk.
# All target files are <= 2 lines and contain only "removed during cleanup"
# comments or @available(*, unavailable) sentinels.

require 'xcodeproj'
require 'pathname'

ROOT = Pathname.new(File.expand_path('..', __dir__))
PROJECT_PATH = ROOT.join('Vision Builder.xcodeproj').to_s

STUBS = %w[
  SmartAssistant.swift
  EnhancedObjectMetadata.swift
  CoordinateDisplayView.swift
  DatasetImageViewer.swift
  LabelingQueueView.swift
  LaunchAnimationView.swift
  SwipeableImageViewer.swift
]

project = Xcodeproj::Project.open(PROJECT_PATH)
removed_refs = 0

STUBS.each do |fname|
  ref = project.files.detect { |f| f.path == fname }
  if ref
    ref.remove_from_project
    removed_refs += 1
    puts "removed reference: #{fname}"
  end
end

project.save
puts "\nReferences removed: #{removed_refs}"

# Delete files from disk
deleted_files = 0
STUBS.each do |fname|
  path = ROOT.join(fname)
  if path.exist?
    path.delete
    deleted_files += 1
    puts "deleted file: #{fname}"
  end
end

puts "\nFiles deleted: #{deleted_files}"
