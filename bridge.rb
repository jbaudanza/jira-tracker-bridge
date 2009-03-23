$LOAD_PATH << './jira4r/lib'

require 'rubygems'
require 'jira4r/jira_tool.rb'
require 'activeresource'
require 'yaml'

CONFIG_FILE = 'config.yml'

if File.exist?(CONFIG_FILE)
  $config = YAML::load_file(CONFIG_FILE)
else
  puts "Missing config file: #{CONFIG_FILE}"
  exit 1
end

class Story < ActiveResource::Base
  self.site = "http://www.pivotaltracker.com/services/v2/projects/:project_id"
  headers['X-TrackerToken'] = $config['tracker_token']
end

$jira = Jira4R::JiraTool.new(2, "http://#{$config['jira_host']}")

$jira.login($config['jira_login'], $config['jira_password'])

def already_scheduled?(jira_issue)
  comments = $jira.getComments(jira_issue.key)
  comments.each do |comment|
    return true if comment.body =~ /^Scheduled in Tracker/
    puts comment.body
  end
  false
end

issues = $jira.getIssuesFromTextSearchWithProject( ['WEB'], '', 1000)

issues.each do |issue|
  if issue.status == '1' # Open issues

    if already_scheduled?(issue)
      puts "skipping #{issue.key}"
      next
    end

    puts "Scheduling #{issue.key}"
    description = issue.description
    description << "\n\nSubmitted through Jira\nhttp://#{$config['jira_host']}:#{$config['jira_port']}/browse/#{issue.key}"

    story = Story.create( :name => issue.summary, 
                          :current_state => 'unstarted', 
                          :requested_by => $config['tracker_requester'], 
                          :description => description, 
                          :story_type => 'bug', 
                          :project_id => $config['tracker_project_id'])

    comment = Jira4R::V2::RemoteComment.new
    comment.body = "Scheduled in Tracker: #{story.url}"
    $jira.addComment(issue.key, comment)
  end
end
