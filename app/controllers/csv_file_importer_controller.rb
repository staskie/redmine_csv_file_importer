require 'csv'
require 'tempfile'
require 'iconv'

class MultipleIssuesForUniqueValue < Exception
end

class NoIssueForUniqueValue < Exception
end

class Journal < ActiveRecord::Base
  def empty?(*args)
    (details.empty? && notes.blank?)
  end
end

class CsvFileImporterController < ApplicationController
  unloadable

  before_filter :find_project, :get_settings

  ISSUE_ATTRS = [:id, :subject, :assigned_to, :fixed_version,
                 :author, :description, :category, :priority, :tracker, :status,
                 :start_date, :due_date, :done_ratio, :estimated_hours,
                 :parent_issue, :watchers, :created_on ]

  TIME_ENTRY_ATTRS = [:issue_id, :comments, :activity_id, :spent_on, :hours,
                      :user_id]

  def index
  end

  def match
    # Delete existing iip to ensure there can't be two iips for a user
    CsvFileImportInProgress.delete_all(["user_id = ?",User.current.id])
    # save import-in-progress data
    iip = CsvFileImportInProgress.find_or_create_by(user_id: User.current.id) 
    iip.import_type = params[:import_type]
    iip.quote_char = params[:wrapper]
    iip.col_sep = params[:splitter]
    iip.encoding = params[:encoding]

    #iip.csv_data = params[:file].read
    iip.created = Time.new
    if params[:file]
      iip.csv_data = params[:file].read
    else
      flash[:warning] = l(:text_file_not_specified)
      redirect_to :action => 'index', :project_id => @project.id
      return
    end
    iip.save

    # Put the timestamp in the params to detect
    # users with two imports in progress
    @import_timestamp = iip.created.strftime("%Y-%m-%d %H:%M:%S")
    @original_filename = params[:file].original_filename

    # display sample
    sample_count = 5
    i = 0
    @samples = []

    # Detects real encoding and converts as necessary
    latin = latin_encoding(iip.encoding, iip.csv_data)
    if latin[:latin]
      iip.csv_data = latin[:data]
      iip.encoding = latin[:encoding]
    end

    begin
      CSV.new(iip.csv_data, {:headers=>true,
                             :converters => :all,
                             :encoding=>iip.encoding,
                             :quote_char=>iip.quote_char,
                             :col_sep=>iip.col_sep}).each do |row|
                               @samples[i] = row

                               i += 1
                               if i >= sample_count
                                 break
                               end
                             end # do
    rescue => e
      msg = e.message + "\n" + e.backtrace.join("\n")
      logger.debug msg
      render :text => "CSV file read error: encoding error or " + e.message
      return
    end


    if @samples.size > 0
      @headers = @samples[0].headers.dup

      (0..@headers.size-1).each do |num|
        unless @headers[num]
          @headers[num] = '------'
          flash[:warning] = "Column name empty error"
        end
        # header encoding
        encoded_header = @headers[num].to_s.dup.force_encoding('utf-8')
        @headers[num]  = encoded_header
      end
    end

    logger.info "Import type : #{iip.import_type}"
    case iip.import_type
    when 'issue'
      attributes = ISSUE_ATTRS
      render_template = 'issue'

    when 'time_entry'
      attributes = TIME_ENTRY_ATTRS
      render_template = 'time_entry'
    end

    # fields
    @attrs = Array.new
    attributes.each do |attr|
      @attrs.push([l_or_humanize(attr, :prefix=>"field_"), attr])
    end
    @project.all_issue_custom_fields.each do |cfield|
      @attrs.push([cfield.name, cfield.name])
    end
    IssueRelation::TYPES.each_pair do |rtype, rinfo|
      @attrs.push([l_or_humanize(rinfo[:name]),rtype])
    end
    @attrs.sort!

    logger.info "Render : match_#{render_template}"
    render(:template => "csv_file_importer/match_" + render_template)

  end

  # Returns the issue object associated with the given value of the given attribute.
  # Raises NoIssueForUniqueValue if not found or MultipleIssuesForUniqueValue
  def issue_for_unique_attr(unique_attr, attr_value, row_data)
    if @issue_by_unique_attr.has_key?(attr_value)
      return @issue_by_unique_attr[attr_value]
    end

    if !(attr_value.blank?) && !(attr_value.to_s =~ /^\d+$/)
      attr_value = attr_value[/#\d+:/].blank? ? attr_value : attr_value[/#\d+:/][/\d+/]
    end

    if unique_attr == "id"
      issues = [Issue.find_by_id(attr_value)]
    else
      query = IssueQuery.new(:name => "_csv_file_importer", :project => @project)
      query.add_filter("status_id", "*", [1])
      query.add_filter(unique_attr, "=", [attr_value])

      begin
        issues = Issue.find :all, :conditions => query.statement, :limit => 2, :include => [ :assigned_to, :status, :tracker, :project, :priority, :category, :fixed_version ]
      rescue NoMethodError
        query = IssueQuery.new(:name => "_csv_file_importer", :project => @project)
        query.add_filter("status_id", "*", [1])
        query.add_filter(unique_attr, "=", [attr_value.to_s])
        issues = Issue.find :all, :conditions => query.statement, :limit => 2, :include => [ :assigned_to, :status, :tracker, :project, :priority, :category, :fixed_version ]
      end
    end
    if issues.size > 1
      @failed_count += 1
      @failed_issues[@failed_count] = row_data
      flash_message(:warning, "Unique field #{unique_attr}#{unique_attr == @unique_attr ? '': '('+@unique_attr+')'} with value '#{attr_value}' has duplicate record")
      raise MultipleIssuesForUniqueValue, "Unique field #{unique_attr} with value '#{attr_value}' has duplicate record"
    else
      if issues.size == 0 || issues == [nil]
        raise NoIssueForUniqueValue, "No issue with #{unique_attr} of '#{attr_value}' found"
      end
      issues.first
    end
  end

  # Returns the id for the given user or raises RecordNotFound
  # Implements a cache of users based on login name
  def user_for_login!(login)
    begin
      if !@user_by_login.has_key?(login)
        @user_by_login[login] = User.find_by_login!(login)
      end
      @user_by_login[login]
    rescue ActiveRecord::RecordNotFound
      @unfound_class = "User"
      @unfound_key = login
      raise
    end
  end
  def user_id_for_login!(login)
    user = user_for_login!(login)
    user ? user.id : nil
  end

  def result
    @handle_count = 0
    @update_count = 0
    @skip_count = 0
    @failed_count = 0
    @failed_events = Hash.new
    @failed_messages = Hash.new
    @affect_projects_issues = Hash.new


    # Retrieve saved import data
    iip = CsvFileImportInProgress.find_or_create_by(user_id: User.current.id)
    if iip == nil
      flash[:error] = "No import is currently in progress"
      return
    end

    if iip.created.strftime("%Y-%m-%d %H:%M:%S") != params[:import_timestamp]
      flash[:error] = "You seem to have started another import " \
        "since starting this one. " \
        "This import cannot be completed"
      return
    end

    # Detects real encoding and converts as necessary
    latin = latin_encoding(iip.encoding, iip.csv_data)
    if latin[:latin]
      iip.csv_data = latin[:data]
      iip.encoding = latin[:encoding]
    end
    logger.info "Encoding OK"
    result_errors = []

    # Import
    case iip.import_type
    when 'issue'
      result_errors = import_issues(iip.csv_data, true, iip.encoding, iip.quote_char, iip.col_sep, params)
      render_template = 'issue'
      logger.info "Issues import in progress..."

    when 'time_entry'
      result_errors = import_time_entries(iip.csv_data, true, iip.encoding, iip.quote_char, iip.col_sep, params)
      render_template = 'time_entry'
      logger.info "iTime entries import in progress..."
    end
    logger.info "Import OK"

    # Clean up after ourselves
    iip.delete

    # Garbage prevention: clean up iips older than 3 days
    CsvFileImportInProgress.delete_all(["created < ?",Time.new - 3*24*60*60])

    logger.info "Result errors ##{result_errors.size}"
    if result_errors.size > 0
      logger.info "Errors : #{result_errors}"
      logger.info "Redirect to index"
      redirect_to(:action => 'index', :project_id => @project.id)
    else
      logger.info "Go to result"
      render(:template => "csv_file_importer/result_" + render_template)
    end
  end

  private

  def find_project
    @project = Project.find(params[:project_id])
  end

  def flash_message(type, text)
    flash[type] ||= ""
    flash[type] += "#{text}<br/>"
  end

  def get_settings
    @settings = Setting.plugin_redmine_csv_file_importer
  end

  # Add ISO-8859-1 (or Latin1) and ISO-8859-15 (or Latin9) character encoding support by converting to UTF-8
  def latin_encoding(pencoding, pdata)
    result = nil
    convert = false

    case pencoding
    when 'U'
      csv_data_lat=pdata.force_encoding("utf-8")
    when 'L1'
      csv_data_lat = Iconv.conv("UTF-8", "ISO8859-1", pdata)
      convert = true

    when 'L9'
      csv_data_lat = Iconv.conv("UTF-8", "ISO8859-15", pdata)
      convert = true
    end

    if convert
      result = { :latin => true, :encoding => 'U', :data => csv_data_lat }
    else
      result = { :latin => false }
    end

    return result
  end

  def import_issues(csv_data, header, encoding, quote_char, col_sep, params)

    default_tracker = params[:default_tracker]
    update_issue = params[:update_issue]
    unique_field = params[:unique_field]
    journal_field = params[:journal_field]
    update_other_project = params[:update_other_project]
    ignore_non_exist = params[:ignore_non_exist]
    fields_map = params[:fields_map]
    unique_attr = fields_map[unique_field]

    # attrs_map is fields_map's invert
    attrs_map = fields_map.invert

    # check params
    errors = []

    if update_issue && unique_attr == nil
      errors << "Unique field hasn't match an issue's field"
      errors << "<br>"
    end

    if attrs_map["subject"].nil?
      errors << l(:error_subject_field_not_defined )
      errors << "<br>"
    end

    if errors.size > 0
      flash[:error] = errors
      return errors
    end

    logger.info "Début de l'importation des demandes..."

    ActiveRecord::Base.transaction do
      CSV.new(csv_data, {:headers=>header, :encoding=>encoding, 
                         :quote_char=>quote_char, :col_sep=>col_sep}).each do |row|

        logger.info "Définition des attributs"

        @handle_count += 1

        id = row[attrs_map["id"]]
        project = Project.find_by_name(row[attrs_map["project"]])
        tracker = Tracker.find_by_name(row[attrs_map["tracker"]])
        status = IssueStatus.find_by_name(row[attrs_map["status"]]) 
        author = row[attrs_map["author"]] != nil ? User.find_by_login(row[attrs_map["author"]]) : User.current
        priority = Enumeration.find_by_name(row[attrs_map["priority"]])
        category = IssueCategory.find_by_name(row[attrs_map["category"]])
        assigned_to = User.find_by_login(row[attrs_map["assigned_to"]])
        fixed_version = Version.find_by_name(row[attrs_map["fixed_version"]])

        journal = nil

        logger.info "Recherche d'une demande existante"


        # new issue or find exists one
        issue = Issue.new
        issue.id = id !=  nil ? id : issue.id
        issue.project_id = project != nil ? project.id : @project.id
        issue.tracker_id = tracker != nil ? tracker.id : default_tracker
        issue.author_id = author != nil ? author.id : User.current.id

        logger.info "Trace 1"

        if update_issue
          # custom field
          if !ISSUE_ATTRS.include?(unique_attr.to_sym)
            issue.available_custom_fields.each do |cf|
              if cf.name == unique_attr
                unique_attr = "cf_#{cf.id}"
                break
              end
            end 
          end

          logger.info "Trace 2"

          if unique_attr == "id"
            issues = [Issue.find_by_id(row[unique_field])]
          else
            query = Query.new(:name => "_csv_file_importer", :project => @project)
            query.add_filter("status_id", "*", [1])
            query.add_filter(unique_attr, "=", [row[unique_field]])

            issues = Issue.find :all, :conditions => query.statement,
              :limit => 2, :include => [ :assigned_to, :status, :tracker, 
                                         :project, :priority, :category, :fixed_version ]
          end

          logger.info "Trace 3"

          if issues.size > 1
            flash[:warning] = "Unique field #{unique_field} has duplicate record"
            @failed_count += 1
            @failed_events[@failed_count] = row
            @failed_messages[@failed_count] = "Unique field #{unique_field} has duplicate record"
            break
          else
            if issues.size > 0
              # found issue
              issue = issues.first

              # ignore other project's issue or not
              if issue.project_id != @project.id && !update_other_project
                @skip_count += 1
                next              
              end

              # ignore closed issue except reopen
              if issue.status.is_closed?
                if status == nil || status.is_closed?
                  @skip_count += 1
                  next
                end
              end

              # init journal
              note = row[journal_field] || ''
              journal = issue.init_journal(author || User.current, 
                                           note || '')

              @update_count += 1
            else
              # ignore none exist issues
              if ignore_non_exist
                @skip_count += 1
                next
              end
            end
          end
        end

        logger.info "Trace 4"

        # project affect
        if project == nil
          project = Project.find_by_id(issue.project_id)
        end
        @affect_projects_issues.has_key?(project.name) ?
          @affect_projects_issues[project.name] += 1 : @affect_projects_issues[project.name] = 1

        # required attributes
        issue.status_id = status != nil ? status.id : issue.status_id
        issue.priority_id = priority != nil ? priority.id : issue.priority_id
        issue.subject = row[attrs_map["subject"]] || issue.subject

        # Check that mandatory fields are not empty 
        if issue.subject.nil? || issue.subject.blank?             
          @failed_count += 1
          @failed_events[@failed_count] = row
          @failed_messages[@failed_count] = l(:error_mandatory_field_missing)

          logger.info "failed_count ##{@failed_count}"
          logger.info "failed : #{row}"

          next
        end

        logger.info "Optional attributes"

        # optional attributes
        issue.description = row[attrs_map["description"]] || issue.description
        issue.category_id = category != nil ? category.id : issue.category_id
        issue.start_date = row[attrs_map["start_date"]] || issue.start_date
        issue.due_date = row[attrs_map["due_date"]] || issue.due_date
        issue.assigned_to_id = assigned_to != nil ? assigned_to.id : issue.assigned_to_id
        issue.fixed_version_id = fixed_version != nil ? fixed_version.id : issue.fixed_version_id
        issue.done_ratio = row[attrs_map["done_ratio"]] || issue.done_ratio
        issue.estimated_hours = row[attrs_map["estimated_hours"]] || issue.estimated_hours

        logger.info "Custom_fields"

        # custom fields
        issue.custom_field_values = issue.available_custom_fields.inject({}) do |h, c|
          if value = row[attrs_map[c.name]]
            h[c.id] = value
          end
          h
        end

        logger.info "Save !"

        begin
          issue.save!
        rescue ActiveRecord::StatementInvalid, ActiveRecord::RecordNotSaved, ActiveRecord::RecordInvalid => ex
          @failed_count += 1
          @failed_events[@failed_count] = row
          @failed_messages[@failed_count] = l(:error_issue_not_saved) + " (#{ex.message[0..49]}...)"
          logger.info "failed_count ##{@failed_count}"
          logger.info "failed : #{row}"
          logger.info "failed error : #{ex}"
          next
        end

        if journal
          journal
        end

      end # do
    end # do

    if @failed_events.size > 0
      @failed_events = @failed_events.sort
      @headers = @failed_events[0][1].headers
    end

    if errors.size == 0
      return []
    end
  end

  def import_time_entries(csv_data, header, encoding, quote_char, col_sep, params) 
    row_counter = 0
    failed_counter = 0

    fields_map = params[:fields_map]

    # attrs_map is fields_map's invert
    attrs_map = fields_map.invert

    # check params
    errors = []

    custom_field = CustomField.find_by_id(@settings['csv_import_issue_id'])
    if attrs_map["issue_id"].nil?
      errors << l(:error_issue_field_not_defined )
      errors << "<br>"
    end

    if attrs_map["user_id"].nil?
      errors << l(:error_user_field_not_defined)
      errors << "<br>"
    end

    if attrs_map["spent_on"].nil?
      errors << l(:error_spent_on_field_not_defined)
      errors << "<br>"
    end

    if attrs_map["activity_id"].nil? 
      errors << l(:error_activity_field_not_defined)
      errors << "<br>"
    end

    if attrs_map["hours"].nil? 
      errors << l(:error_hours_field_not_defined)
      errors << "<br>"
    end

    logger.info "Errors ##{errors.size}"
    if errors.size > 0 
      logger.info "Errors : " + errors.to_s
      flash[:error] = errors.join(" ")
      return errors
    end

    # if update_issue && unique_attr == nil
    #   flash[:error] = "Unique field hasn't match an issue's field"
    #   return
    # end

    ActiveRecord::Base.transaction do
      CSV.new(csv_data, {:headers=>header, :encoding=>encoding, 
                         :quote_char=>quote_char, :col_sep=>col_sep}).each do |row|

        journal = nil

        @handle_count += 1
        logger.info "Row processed :  #{row}"

        # Check that mandatory fields are not empty 
        if (row[attrs_map["issue_id"]].blank? ||
            row[attrs_map["hours"]].blank? ||
            row[attrs_map["activity_id"]].blank? ||
            row[attrs_map["user_id"]].blank? ||
            row[attrs_map["spent_on"]].blank?)

          @failed_count += 1
          @failed_events[@failed_count] = row
          @failed_messages[@failed_count] = l(:error_mandatory_field_missing)

          logger.info "failed_count ##{@failed_count}"
          logger.info "failed : #{row}"

          next
        end

        logger.info "success : #{row}"
        project = Project.find_by_name(row[attrs_map["project"]])

        logger.info "project : #{project}"

        begin
          if row[attrs_map["issue_id"]].nil?
            # find issue from custom field
            custom_field = CustomField.find_by_id(@settings['csv_import_issue_id'])
            custom_field_value = CustomValue.where(:custom_field_id => custom_field.id, 
                                                   :value => row[attrs_map[custom_field.name]]).first
            issue_id = Issue.find_by_id(custom_field_value.customized_id)
            issue_id = issue_id.id
          else
            issue_id = Issue.find_by_id(row[attrs_map["issue_id"]])
            issue_id = issue_id.id
          end
        rescue NilClass::NoMethodError => ex
          @failed_count += 1
          @failed_events[@failed_count] = row
          @failed_messages[@failed_count] = l(:error_issue_id_not_existing) + " (#{ex.message[0..49]}...)"
          logger.info "failed_count ##{@failed_count}"
          logger.info "failed : #{row}"
          logger.info "failed error : #{ex}"
          next
        end

        # new time entry
        time = TimeEntry.new

        time.issue_id = issue_id
        time.project_id = project != nil ? project.id : time.issue.project_id
        #time.issue_id = Issue.find_by_name ...
        TimeEntryActivity.find_by_name(row[attrs_map["activity_id"]].strip)
        time.spent_on = row[attrs_map["spent_on"]]
        #time.activity = activity_id
        time.activity = TimeEntryActivity.find_by_name(row[attrs_map["activity_id"]].strip)
        time.hours = row[attrs_map["hours"]]

        # Truncate comments to 255 chars
        time.comments = row[attrs_map["comments"]].mb_chars[0..255].strip.to_s if row[attrs_map["comments"]].present?
        time.user = User.find_by_login(row[attrs_map["user_id"]].strip)

        # Just for log
        t_s = ""
        time.attributes.sort.each do | a_n, a_v |
          t_s += "#{a_n} : #{a_v} | "
        end

        logger.info "TimeEntry : #{t_s}"

        begin
          time.save!
        rescue ActiveRecord::StatementInvalid, ActiveRecord::RecordNotSaved, ActiveRecord::RecordInvalid => ex
          @failed_count += 1
          @failed_events[@failed_count] = row
          @failed_messages[@failed_count] = l(:error_time_entry_not_saved) + " (#{ex.message[0..49]}...)"
          logger.info "failed_count ##{@failed_count}"
          logger.info "failed : #{row}"
          logger.info "failed error : #{ex}"
          next
        end
      end
    end

    if @failed_events.size > 0
      @failed_events = @failed_events.sort
      @headers = @failed_events[0][1].headers
      logger.info "Failed summary : #{@failed_events}"
    end

    if errors.size == 0
      return []
    end
  end


end
