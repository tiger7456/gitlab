# SystemNoteService
#
# Used for creating system notes (e.g., when a user references a merge request
# from an issue, an issue's assignee changes, an issue is closed, etc.)
module SystemNoteService
  extend self

  # Called when commits are added to a Merge Request
  #
  # noteable         - Noteable object
  # project          - Project owning noteable
  # author           - User performing the change
  # new_commits      - Array of Commits added since last push
  # existing_commits - Array of Commits added in a previous push
  # oldrev           - Optional String SHA of a previous Commit
  #
  # See new_commit_summary and existing_commit_summary.
  #
  # Returns the created Note object
  def add_commits(noteable, project, author, new_commits, existing_commits = [], oldrev = nil)
    total_count  = new_commits.length + existing_commits.length
    commits_text = "#{total_count} 次提交"

    body = "增加了 #{commits_text}:\n\n"
    body << existing_commit_summary(noteable, existing_commits, oldrev)
    body << new_commit_summary(new_commits).join("\n")
    body << "\n\n[与上一版本比较差异](#{diff_comparison_url(noteable, project, oldrev)})"

    create_note(NoteSummary.new(noteable, project, author, body, action: 'commit', commit_count: total_count))
  end

  # Called when the assignee of a Noteable is changed or removed
  #
  # noteable - Noteable object
  # project  - Project owning noteable
  # author   - User performing the change
  # assignee - User being assigned, or nil
  #
  # Example Note text:
  #
  #   "removed assignee"
  #
  #   "assigned to @rspeicher"
  #
  # Returns the created Note object
  def change_assignee(noteable, project, author, assignee)
    body = assignee.nil? ? '已删除指派' : "指派给 #{assignee.to_reference}"

    create_note(NoteSummary.new(noteable, project, author, body, action: 'assignee'))
  end

  # Called when the assignees of an Issue is changed or removed
  #
  # issue - Issue object
  # project  - Project owning noteable
  # author   - User performing the change
  # assignees - Users being assigned, or nil
  #
  # Example Note text:
  #
  #   "removed all assignees"
  #
  #   "assigned to @user1 additionally to @user2"
  #
  #   "assigned to @user1, @user2 and @user3 and unassigned from @user4 and @user5"
  #
  #   "assigned to @user1 and @user2"
  #
  # Returns the created Note object
  def change_issue_assignees(issue, project, author, old_assignees)
    body =
      if issue.assignees.any? && old_assignees.any?
        unassigned_users = old_assignees - issue.assignees
        added_users = issue.assignees.to_a - old_assignees

        text_parts = []
        text_parts << "指派给 #{added_users.map(&:to_reference).to_sentence}" if added_users.any?
        text_parts << "取消指派给 #{unassigned_users.map(&:to_reference).to_sentence}" if unassigned_users.any?

        text_parts.join(' and ')
      elsif old_assignees.any?
        "已删除的指派"
      elsif issue.assignees.any?
        "指派给 #{issue.assignees.map(&:to_reference).to_sentence}"
      end

    create_note(NoteSummary.new(issue, project, author, body, action: 'assignee'))
  end

  # Called when one or more labels on a Noteable are added and/or removed
  #
  # noteable       - Noteable object
  # project        - Project owning noteable
  # author         - User performing the change
  # added_labels   - Array of Labels added
  # removed_labels - Array of Labels removed
  #
  # Example Note text:
  #
  #   "added ~1 and removed ~2 ~3 labels"
  #
  #   "added ~4 label"
  #
  #   "removed ~5 label"
  #
  # Returns the created Note object
  def change_label(noteable, project, author, added_labels, removed_labels)
    labels_count = added_labels.count + removed_labels.count

    references     = ->(label) { label.to_reference(format: :id) }
    added_labels   = added_labels.map(&references).join(' ')
    removed_labels = removed_labels.map(&references).join(' ')

    body = ''

    if added_labels.present?
      body << "增加 #{added_labels}"
      body << ' 并 ' if removed_labels.present?
    end

    if removed_labels.present?
      body << "删除 #{removed_labels}"
    end

    body << ' ' << '标记'

    create_note(NoteSummary.new(noteable, project, author, body, action: 'label'))
  end

  # Called when the milestone of a Noteable is changed
  #
  # noteable  - Noteable object
  # project   - Project owning noteable
  # author    - User performing the change
  # milestone - Milestone being assigned, or nil
  #
  # Example Note text:
  #
  #   "removed milestone"
  #
  #   "changed milestone to 7.11"
  #
  # Returns the created Note object
  def change_milestone(noteable, project, author, milestone)
    format = milestone&.group_milestone? ? :name : :iid
    body = milestone.nil? ? '已删除里程碑' : "修改里程碑为 #{milestone.to_reference(project, format: format)}"

    create_note(NoteSummary.new(noteable, project, author, body, action: 'milestone'))
  end

  def status_zh(status)
    case status
    when 'merged'
      "已合并"
    when 'reopened'
      "重新打开"
    when 'closed'
      "已关闭"
    when 'opened'
      "已打开"
    when 'locked'
      "已锁定"
    else
      status.to_s
    end
  end

  def noteable_zh(noteable_name)
    case noteable_name
    when 'issue'
      "问题"
    when 'merge request'
      "合并请求"
    else
      noteable_name
    end
  end

  # Called when the estimated time of a Noteable is changed
  #
  # noteable      - Noteable object
  # project       - Project owning noteable
  # author        - User performing the change
  # time_estimate - Estimated time
  #
  # Example Note text:
  #
  #   "removed time estimate"
  #
  #   "changed time estimate to 3d 5h"
  #
  # Returns the created Note object
  def change_time_estimate(noteable, project, author)
    parsed_time = Gitlab::TimeTrackingFormatter.output(noteable.time_estimate)
    body = if noteable.time_estimate == 0
             "删除预估工时"
           else
             "将预估工时更改为 #{parsed_time}"
           end

    create_note(NoteSummary.new(noteable, project, author, body, action: 'time_tracking'))
  end

  # Called when the spent time of a Noteable is changed
  #
  # noteable   - Noteable object
  # project    - Project owning noteable
  # author     - User performing the change
  # time_spent - Spent time
  #
  # Example Note text:
  #
  #   "removed time spent"
  #
  #   "added 2h 30m of time spent"
  #
  # Returns the created Note object
  def change_time_spent(noteable, project, author)
    time_spent = noteable.time_spent

    if time_spent == :reset
      body = "删除工时"
    else
      parsed_time = Gitlab::TimeTrackingFormatter.output(time_spent.abs)
      action = time_spent > 0 ? '增加' : '减去'
      body = "#{action} #{parsed_time} 工时"
    end

    create_note(NoteSummary.new(noteable, project, author, body, action: 'time_tracking'))
  end

  # Called when the status of a Noteable is changed
  #
  # noteable - Noteable object
  # project  - Project owning noteable
  # author   - User performing the change
  # status   - String status
  # source   - Mentionable performing the change, or nil
  #
  # Example Note text:
  #
  #   "merged"
  #
  #   "closed via bc17db76"
  #
  # Returns the created Note object
  def change_status(noteable, project, author, status, source)
    body = ""
    body << "被 #{source.gfm_reference(project)} " if source
    body << "#{status_zh(status)}"

    action = status == 'reopened' ? 'opened' : status

    create_note(NoteSummary.new(noteable, project, author, body, action: action))
  end

  # Called when 'merge when pipeline succeeds' is executed
  def merge_when_pipeline_succeeds(noteable, project, author, last_commit)
    body = "流水线 #{last_commit.to_reference(project)} 成功后，启用自动合并"

    create_note(NoteSummary.new(noteable, project, author, body, action: 'merge'))
  end

  # Called when 'merge when pipeline succeeds' is canceled
  def cancel_merge_when_pipeline_succeeds(noteable, project, author)
    body = '取消自动合并'

    create_note(NoteSummary.new(noteable, project, author, body, action: 'merge'))
  end

  def remove_merge_request_wip(noteable, project, author)
    body = '将合并请求重新标记为 **进行中(WIP)**'

    create_note(NoteSummary.new(noteable, project, author, body, action: 'title'))
  end

  def add_merge_request_wip(noteable, project, author)
    body = '将合并请求标记为 **进行中(WIP)**'

    create_note(NoteSummary.new(noteable, project, author, body, action: 'title'))
  end

  def add_merge_request_wip_from_commit(noteable, project, author, commit)
    body = "marked as a **Work In Progress** from #{commit.to_reference(project)}"

    create_note(NoteSummary.new(noteable, project, author, body, action: 'title'))
  end

  def resolve_all_discussions(merge_request, project, author)
    body = "解决了所有讨论"

    create_note(NoteSummary.new(merge_request, project, author, body, action: 'discussion'))
  end

  def discussion_continued_in_issue(discussion, project, author, issue)
    body = "创建 #{issue.to_reference} 以继续此讨论"
    note_attributes = discussion.reply_attributes.merge(project: project, author: author, note: body)

    note = Note.create(note_attributes.merge(system: true))
    note.system_note_metadata = SystemNoteMetadata.new(action: 'discussion')

    note
  end

  def diff_discussion_outdated(discussion, project, author, change_position)
    merge_request = discussion.noteable
    diff_refs = change_position.diff_refs
    version_index = merge_request.merge_request_diffs.viewable.count

    body = "changed this line in"
    if version_params = merge_request.version_params_for(diff_refs)
      line_code = change_position.line_code(project.repository)
      url = url_helpers.diffs_project_merge_request_url(project, merge_request, version_params.merge(anchor: line_code))

      body << " [version #{version_index} of the diff](#{url})"
    else
      body << " version #{version_index} of the diff"
    end

    note_attributes = discussion.reply_attributes.merge(project: project, author: author, note: body)
    note = Note.create(note_attributes.merge(system: true))
    note.system_note_metadata = SystemNoteMetadata.new(action: 'outdated')

    note
  end

  # Called when the title of a Noteable is changed
  #
  # noteable  - Noteable object that responds to `title`
  # project   - Project owning noteable
  # author    - User performing the change
  # old_title - Previous String title
  #
  # Example Note text:
  #
  #   "changed title from **Old** to **New**"
  #
  # Returns the created Note object
  def change_title(noteable, project, author, old_title)
    new_title = noteable.title.dup

    old_diffs, new_diffs = Gitlab::Diff::InlineDiff.new(old_title, new_title).inline_diffs

    marked_old_title = Gitlab::Diff::InlineDiffMarkdownMarker.new(old_title).mark(old_diffs, mode: :deletion)
    marked_new_title = Gitlab::Diff::InlineDiffMarkdownMarker.new(new_title).mark(new_diffs, mode: :addition)

    body = "将标题由 **#{marked_old_title}** 修改为 **#{marked_new_title}**"

    create_note(NoteSummary.new(noteable, project, author, body, action: 'title'))
  end

  # Called when the description of a Noteable is changed
  #
  # noteable  - Noteable object that responds to `description`
  # project   - Project owning noteable
  # author    - User performing the change
  #
  # Example Note text:
  #
  #   "changed the description"
  #
  # Returns the created Note object
  def change_description(noteable, project, author)
    body = 'changed the description'

    create_note(NoteSummary.new(noteable, project, author, body, action: 'description'))
  end

  # Called when the confidentiality changes
  #
  # issue   - Issue object
  # project - Project owning the issue
  # author  - User performing the change
  #
  # Example Note text:
  #
  #   "made the issue confidential"
  #
  # Returns the created Note object
  def change_issue_confidentiality(issue, project, author)
    if issue.confidential
      body = '将问题设置为保密'
      action = 'confidential'
    else
      body = '将问题设置为所有人可见'
      action = 'visible'
    end

    create_note(NoteSummary.new(issue, project, author, body, action: action))
  end

  # Called when a branch in Noteable is changed
  #
  # noteable    - Noteable object
  # project     - Project owning noteable
  # author      - User performing the change
  # branch_type - 'source' or 'target'
  # old_branch  - old branch name
  # new_branch  - new branch nmae
  #
  # Example Note text:
  #
  #   "changed target branch from `Old` to `New`"
  #
  # Returns the created Note object
  def change_branch(noteable, project, author, branch_type, old_branch, new_branch)
    case branch_type
    when 'source'
      body = "源分支从 `#{old_branch}` 变更为 `#{new_branch}`"
    when 'target'
      body = "目标分支从 `#{old_branch}` 变更为 `#{new_branch}`"
    end

    create_note(NoteSummary.new(noteable, project, author, body, action: 'branch'))
  end

  # Called when a branch in Noteable is added or deleted
  #
  # noteable    - Noteable object
  # project     - Project owning noteable
  # author      - User performing the change
  # branch_type - :source or :target
  # branch      - branch name
  # presence    - :add or :delete
  #
  # Example Note text:
  #
  #   "restored target branch `feature`"
  #
  # Returns the created Note object
  def change_branch_presence(noteable, project, author, branch_type, branch, presence)
    verb =
      if presence == :add
        '恢复'
      else
        '删除'
      end

    case branch_type
    when :source
      body = "#{verb} 源分支 `#{branch}`"
    when :target
      body = "#{verb} 目标分支 `#{branch}`"
    end

    create_note(NoteSummary.new(noteable, project, author, body, action: 'branch'))
  end

  # Called when a branch is created from the 'new branch' button on a issue
  # Example note text:
  #
  #   "created branch `201-issue-branch-button`"
  def new_issue_branch(issue, project, author, branch)
    link = url_helpers.project_compare_url(project, from: project.default_branch, to: branch)

    body = "创建分支 [`#{branch}`](#{link})"

    create_note(NoteSummary.new(issue, project, author, body, action: 'branch'))
  end

  # Called when a Mentionable references a Noteable
  #
  # noteable  - Noteable object being referenced
  # mentioner - Mentionable object
  # author    - User performing the reference
  #
  # Example Note text:
  #
  #   "mentioned in #1"
  #
  #   "mentioned in !2"
  #
  #   "mentioned in 54f7727c"
  #
  # See cross_reference_note_content.
  #
  # Returns the created Note object
  def cross_reference(noteable, mentioner, author)
    return if cross_reference_disallowed?(noteable, mentioner)

    gfm_reference = mentioner.gfm_reference(noteable.project)
    body = cross_reference_note_content(gfm_reference)

    if noteable.is_a?(ExternalIssue)
      noteable.project.issues_tracker.create_cross_reference_note(noteable, mentioner, author)
    else
      create_note(NoteSummary.new(noteable, noteable.project, author, body, action: 'cross_reference'))
    end
  end

  # Check if a cross-reference is disallowed
  #
  # This method prevents adding a "mentioned in !1" note on every single commit
  # in a merge request. Additionally, it prevents the creation of references to
  # external issues (which would fail).
  #
  # noteable  - Noteable object being referenced
  # mentioner - Mentionable object
  #
  # Returns Boolean
  def cross_reference_disallowed?(noteable, mentioner)
    return true if noteable.is_a?(ExternalIssue) && !noteable.project.jira_tracker_active?
    return false unless mentioner.is_a?(MergeRequest)
    return false unless noteable.is_a?(Commit)

    mentioner.commits.include?(noteable)
  end

  # Check if a cross reference to a noteable from a mentioner already exists
  #
  # This method is used to prevent multiple notes being created for a mention
  # when a issue is updated, for example. The method also calls notes_for_mentioner
  # to check if the mentioner is a commit, and return matches only on commit hash
  # instead of project + commit, to avoid repeated mentions from forks.
  #
  # noteable  - Noteable object being referenced
  # mentioner - Mentionable object
  #
  # Returns Boolean
  def cross_reference_exists?(noteable, mentioner)
    # Initial scope should be system notes of this noteable type
    notes = Note.system.where(noteable_type: noteable.class)

    notes =
      if noteable.is_a?(Commit)
        # Commits have non-integer IDs, so they're stored in `commit_id`
        notes.where(commit_id: noteable.id)
      else
        notes.where(noteable_id: noteable.id)
      end

    notes_for_mentioner(mentioner, noteable, notes).exists?
  end

  # Build an Array of lines detailing each commit added in a merge request
  #
  # new_commits - Array of new Commit objects
  #
  # Returns an Array of Strings
  def new_commit_summary(new_commits)
    new_commits.collect do |commit|
      "* #{commit.short_id} - #{escape_html(commit.title)}"
    end
  end

  # Called when the status of a Task has changed
  #
  # noteable  - Noteable object.
  # project   - Project owning noteable
  # author    - User performing the change
  # new_task  - TaskList::Item object.
  #
  # Example Note text:
  #
  #   "marked the task Whatever as completed."
  #
  # Returns the created Note object
  def change_task_status(noteable, project, author, new_task)
    status_label = new_task.complete? ? Taskable::COMPLETED : Taskable::INCOMPLETE
    body = "将任务 **#{new_task.source}** 标记为 #{status_label}"

    create_note(NoteSummary.new(noteable, project, author, body, action: 'task'))
  end

  # Called when noteable has been moved to another project
  #
  # direction    - symbol, :to or :from
  # noteable     - Noteable object
  # noteable_ref - Referenced noteable
  # author       - User performing the move
  #
  # Example Note text:
  #
  #   "moved to some_namespace/project_new#11"
  #
  # Returns the created Note object
  def noteable_moved(noteable, project, noteable_ref, author, direction:)
    unless [:to, :from].include?(direction)
      raise ArgumentError, "Invalid direction `#{direction}`"
    end

    cross_reference = noteable_ref.to_reference(project)
    case direction
    when :to
      body = "移动到 #{cross_reference}"
    when :from
      body = "来自于 #{cross_reference}"
    end

    create_note(NoteSummary.new(noteable, project, author, body, action: 'moved'))
  end

  # Called when a Noteable has been marked as a duplicate of another Issue
  #
  # noteable        - Noteable object
  # project         - Project owning noteable
  # author          - User performing the change
  # canonical_issue - Issue that this is a duplicate of
  #
  # Example Note text:
  #
  #   "marked this issue as a duplicate of #1234"
  #
  #   "marked this issue as a duplicate of other_project#5678"
  #
  # Returns the created Note object
  def mark_duplicate_issue(noteable, project, author, canonical_issue)
    body = "marked this issue as a duplicate of #{canonical_issue.to_reference(project)}"
    create_note(NoteSummary.new(noteable, project, author, body, action: 'duplicate'))
  end

  # Called when a Noteable has been marked as the canonical Issue of a duplicate
  #
  # noteable        - Noteable object
  # project         - Project owning noteable
  # author          - User performing the change
  # duplicate_issue - Issue that was a duplicate of this
  #
  # Example Note text:
  #
  #   "marked #1234 as a duplicate of this issue"
  #
  #   "marked other_project#5678 as a duplicate of this issue"
  #
  # Returns the created Note object
  def mark_canonical_issue_of_duplicate(noteable, project, author, duplicate_issue)
    body = "标记 #{duplicate_issue.to_reference(project)} 和这个问题重复"
    create_note(NoteSummary.new(noteable, project, author, body, action: 'duplicate'))
  end

  private

  def notes_for_mentioner(mentioner, noteable, notes)
    if mentioner.is_a?(Commit)
      text = "#{cross_reference_note_prefix}%#{mentioner.to_reference(nil)}"
      notes.where('(note LIKE ? OR note LIKE ?)', text, text.capitalize)
    else
      gfm_reference = mentioner.gfm_reference(noteable.project)
      text = cross_reference_note_content(gfm_reference)
      notes.where(note: [text, text.capitalize])
    end
  end

  def create_note(note_summary)
    note = Note.create(note_summary.note.merge(system: true))
    note.system_note_metadata = SystemNoteMetadata.new(note_summary.metadata) if note_summary.metadata?

    note
  end

  def cross_reference_note_prefix
    '被提及 '
  end

  def cross_reference_note_content(gfm_reference)
    "#{cross_reference_note_prefix}#{gfm_reference}"
  end

  # Build a single line summarizing existing commits being added in a merge
  # request
  #
  # noteable         - MergeRequest object
  # existing_commits - Array of existing Commit objects
  # oldrev           - Optional String SHA of a previous Commit
  #
  # Examples:
  #
  #   "* ea0f8418...2f4426b7 - 24 commits from branch `master`"
  #
  #   "* ea0f8418..4188f0ea - 15 commits from branch `fork:master`"
  #
  #   "* ea0f8418 - 1 commit from branch `feature`"
  #
  # Returns a newline-terminated String
  def existing_commit_summary(noteable, existing_commits, oldrev = nil)
    return '' if existing_commits.empty?

    count = existing_commits.size

    commit_ids = if count == 1
                   existing_commits.first.short_id
                 else
                   if oldrev && !Gitlab::Git.blank_ref?(oldrev)
                     "#{Commit.truncate_sha(oldrev)}...#{existing_commits.last.short_id}"
                   else
                     "#{existing_commits.first.short_id}..#{existing_commits.last.short_id}"
                   end
                 end

    commits_text = "#{count} ".pluralize(count,'次提交','次提交')

    branch = noteable.target_branch
    branch = "#{noteable.target_project_namespace}:#{branch}" if noteable.for_fork?

    "* #{commit_ids} - #{commits_text} 来自于分支 `#{branch}`\n"
  end

  def escape_html(text)
    Rack::Utils.escape_html(text)
  end

  def url_helpers
    @url_helpers ||= Gitlab::Routing.url_helpers
  end

  def diff_comparison_url(merge_request, project, oldrev)
    diff_id = merge_request.merge_request_diff.id

    url_helpers.diffs_project_merge_request_url(
      project,
      merge_request,
      diff_id: diff_id,
      start_sha: oldrev
    )
  end
end
