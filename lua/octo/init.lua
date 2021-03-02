local gh = require "octo.gh"
local signs = require "octo.signs"
local constants = require "octo.constants"
local util = require "octo.util"
local graphql = require "octo.graphql"
local writers = require "octo.writers"
local folds = require "octo.folds"
local vim = vim
local api = vim.api
local format = string.format
local json = {
  parse = vim.fn.json_decode,
}

local M = {}

function M.check_login()
  gh.run(
    {
      args = {"auth", "status"},
      cb = function(_, err)
        local _, _, name = string.find(err, "Logged in to [^%s]+ as ([^%s]+)")
        vim.g.octo_loggedin_user = name
      end
    }
  )
end

function M.load_buffer(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  local bufname = vim.fn.bufname(bufnr)
  local repo, type, number = string.match(bufname, "octo://(.+)/(.+)/(%d+)")
  if not repo or not type or not number then
    api.nvim_err_writeln("Incorrect buffer: " .. bufname)
    return
  end

  M.load(bufnr, function(obj)
    M.create_buffer(type, obj, repo, false)
  end)
end


function M.load(bufnr, cb)
  local bufname = vim.fn.bufname(bufnr)
  local repo, type, number = string.match(bufname, "octo://(.+)/(.+)/(%d+)")
  if not repo or not type or not number then
    api.nvim_err_writeln("Incorrect buffer: " .. bufname)
    return
  end
  local owner = vim.split(repo, "/")[1]
  local name = vim.split(repo, "/")[2]
  local query, key
  if type == "pull" then
    query = graphql("pull_request_query", owner, name, number)
    key = "pullRequest"
  elseif type == "issue" then
    query = graphql("issue_query", owner, name, number)
    key = "issue"
  end
  gh.run(
    {
      args = {"api", "graphql", "--paginate", "-f", format("query=%s", query)},
      cb = function(output, stderr)
        if stderr and not util.is_blank(stderr) then
          api.nvim_err_writeln(stderr)
        elseif output then
          local resp = util.aggregate_pages(output, format("data.repository.%s.timelineItems.nodes", key))
          local obj = resp.data.repository[key]
            cb(obj)
        end
      end
    }
  )
end

-- This function accumulates all the taggable users into a single list that
-- gets set as a buffer variable `taggable_users`. If this list of users
-- is needed syncronously, this function will need to be refactored.
-- The list of taggable users should contain:
--   - The PR author
--   - The authors of all the existing comments
--   - The contributors of the repo
local function async_fetch_taggable_users(bufnr, repo, participants)
  local users = api.nvim_buf_get_var(bufnr, "taggable_users") or {}

  -- add participants
  for _, p in pairs(participants) do
    table.insert(users, p.login)
  end

  -- add comment authors
  local comments_metadata = api.nvim_buf_get_var(bufnr, "comments")
  for _, c in pairs(comments_metadata) do
    table.insert(users, c.author)
  end

  -- add repo contributors
  api.nvim_buf_set_var(bufnr, "taggable_users", users)
  gh.run(
    {
      args = {"api", format("repos/%s/contributors", repo)},
      cb = function(response)
        local resp = json.parse(response)
        for _, contributor in ipairs(resp) do
          table.insert(users, contributor.login)
        end
        api.nvim_buf_set_var(bufnr, "taggable_users", users)
      end
    }
  )
end

-- This function fetches the issues in the repo so they can be used for
-- completion.
local function async_fetch_issues(bufnr, repo)
  gh.run(
    {
      args = {"api", format(format("repos/%s/issues", repo))},
      cb = function(response)
        local issues_metadata = {}
        local resp = json.parse(response)
        for _, issue in ipairs(resp) do
          table.insert(issues_metadata, {number = issue.number, title = issue.title})
        end
        api.nvim_buf_set_var(bufnr, "issues", issues_metadata)
      end
    }
  )
end

function M.create_buffer(type, obj, repo, create)
  if not obj.id then
    api.nvim_err_writeln(format("Cannot find issue in %s", repo))
    return
  end

  local iid = obj.id
  local number = obj.number
  local state = obj.state

  local bufnr
  if create then
    bufnr = api.nvim_create_buf(true, false)
    api.nvim_set_current_buf(bufnr)
    vim.cmd(format("file octo://%s/%s/%d", repo, type, number))
  else
    bufnr = api.nvim_get_current_buf()
  end

  api.nvim_set_current_buf(bufnr)

  -- clear buffer
  api.nvim_buf_set_lines(bufnr, 0, -1, false, {})

  -- delete extmarks
  for _, m in ipairs(api.nvim_buf_get_extmarks(bufnr, constants.OCTO_COMMENT_NS, 0, -1, {})) do
    api.nvim_buf_del_extmark(bufnr, constants.OCTO_COMMENT_NS, m[1])
  end

  -- configure buffer
  api.nvim_buf_set_option(bufnr, "filetype", "octo_issue")
  api.nvim_buf_set_option(bufnr, "buftype", "acwrite")
  vim.cmd [[setlocal fillchars=fold:⠀,foldopen:⠀,foldclose:⠀,foldsep:⠀]]
  vim.cmd [[setlocal foldtext=v:lua.OctoFoldText()]]
  vim.cmd [[setlocal foldmethod=manual]]
  vim.cmd [[setlocal foldenable]]
  vim.cmd [[setlocal foldcolumn=3]]
  vim.cmd [[setlocal foldlevelstart=99]]
  vim.cmd [[setlocal conceallevel=2]]
  vim.cmd [[setlocal syntax=markdown]]

  -- register issue
  api.nvim_buf_set_var(bufnr, "iid", iid)
  api.nvim_buf_set_var(bufnr, "number", number)
  api.nvim_buf_set_var(bufnr, "repo", repo)
  api.nvim_buf_set_var(bufnr, "state", state)
  api.nvim_buf_set_var(bufnr, "labels", obj.labels)
  api.nvim_buf_set_var(bufnr, "assignees", obj.assignees)
  api.nvim_buf_set_var(bufnr, "milestone", obj.milestone)
  api.nvim_buf_set_var(bufnr, "cards", obj.projectCards)
  api.nvim_buf_set_var(bufnr, "taggable_users", {obj.author.login})

  -- buffer mappings
  M.apply_buffer_mappings(bufnr, type)

  -- write title
  writers.write_title(bufnr, obj.title, 1)

  -- write details in buffer
  writers.write_details(bufnr, obj)

  -- write issue/pr status
  writers.write_state(bufnr, state:upper(), number)

  -- write body
  writers.write_body(bufnr, obj)

  -- write body reactions
  local reaction_line = writers.write_reactions(bufnr, obj.reactionGroups, api.nvim_buf_line_count(bufnr) - 1)
  api.nvim_buf_set_var(bufnr, "body_reactions", obj.reactions)
  api.nvim_buf_set_var(bufnr, "body_reaction_line", reaction_line)

  -- initialize comments metadata
  api.nvim_buf_set_var(bufnr, "comments", {})

  -- PRs
  if obj.commits then
    -- for pulls, store some additional info
    api.nvim_buf_set_var(
      bufnr,
      "pr",
      {
        id = obj.id,
        isDraft = obj.isDraft,
        merged = obj.merged,
        headRefName = obj.headRefName,
        headRefSHA = obj.headRefOid,
        baseRefName = obj.baseRefName,
        baseRefSHA = obj.baseRefOid,
        baseRepoName = obj.baseRepository.nameWithOwner
      }
    )
  end

  -- write timeline items
  local review_thread_map = {}

  for _, item in ipairs(obj.timelineItems.nodes) do
    if item.__typename == "IssueComment" then
      -- write the comment
      local start_line, end_line = writers.write_comment(bufnr, item, "IssueComment")
      folds.create(start_line+1, end_line, true)

    elseif item.__typename == "PullRequestReview" then

      -- A review can have 0+ threads
      local threads = {}
      for _, comment in ipairs(item.comments.nodes) do
        for _, reviewThread in ipairs(obj.reviewThreads.nodes) do
          if comment.id == reviewThread.comments.nodes[1].id then
            -- found a thread for the current review
            table.insert(threads, reviewThread)
          end
        end
      end

      -- skip reviews with no threads and empty body
      if #threads == 0 and util.is_blank(item.body) then
        goto continue
      end

      -- print review header and top level comment
      -- local line = api.nvim_buf_line_count(bufnr) - 1
      -- writers.write_block({"", ""}, {bufnr = bufnr, line = line})
      -- local max_length = vim.fn.winwidth(0) - 10 - vim.wo.foldcolumn
      -- local header_vt = {{format("┌%s┐", string.rep("─", max_length + 2))}}
      -- api.nvim_buf_set_extmark(bufnr, constants.OCTO_THREAD_HEADER_VT_NS, line, 0, { virt_text=header_vt, virt_text_pos='overlay'})
      local review_start, review_end = writers.write_comment(bufnr, item, "PullRequestReview")

      if #threads > 0 then
        -- print each of the threads
        for _, thread in ipairs(threads) do
          local thread_start, thread_end
          for _,comment in ipairs(thread.comments.nodes) do
            if comment.replyTo == vim.NIL then

              -- review thread header
              local start_line = thread.originalStartLine ~= vim.NIL and thread.originalStartLine or thread.originalLine
              local end_line = thread.originalLine
              writers.write_review_thread_header(bufnr, {
                path = thread.path,
                start_line = start_line,
                end_line = end_line,
                isOutdated = thread.isOutdated,
                isResolved = thread.isResolved,
              })

              -- write diff lines
              thread_start, thread_end = writers.write_commented_lines(bufnr, comment.diffHunk, thread.diffSide, start_line, end_line)
            end
            local comment_start, comment_end = writers.write_comment(bufnr, comment, "PullRequestReviewComment")
            folds.create(comment_start+1, comment_end, true)
            thread_end = comment_end
            review_end = comment_end
          end
          folds.create(thread_start-1, thread_end, not thread.isCollapsed)

          -- mark the thread region
          local thread_mark_id = api.nvim_buf_set_extmark(
            bufnr,
            constants.OCTO_THREAD_NS,
            thread_start - 1,
            0,
            {
              end_line = thread_end,
              end_col = 0
            }
          )
          -- store it as a buffer var to be able to find a thread_id given the cursor position
          review_thread_map[tostring(thread_mark_id)] = {
            thread_id = thread.id,
            first_comment_id = thread.comments.nodes[1].id
          }
        end
        folds.create(review_start+1, review_end, true)
      end
    end
    ::continue::
  end
  api.nvim_buf_set_var(bufnr, "reviewThreadMap", review_thread_map)

  async_fetch_taggable_users(bufnr, repo, obj.participants.nodes)
  async_fetch_issues(bufnr, repo)

  -- show signs
  signs.render_signcolumn(bufnr)

  -- drop undo history
  vim.fn["octo#clear_history"]()

  -- reset modified option
  api.nvim_buf_set_option(bufnr, "modified", false)

  vim.cmd [[ augroup octo_buffer_autocmds ]]
  vim.cmd [[ au! * <buffer> ]]
  vim.cmd [[ au TextChanged <buffer> lua require"octo.signs".render_signcolumn() ]]
  vim.cmd [[ au TextChangedI <buffer> lua require"octo.signs".render_signcolumn() ]]
  vim.cmd [[ au InsertEnter <buffer> lua require"octo".enter_insert() ]]
  vim.cmd [[ au InsertLeave <buffer> lua require"octo".leave_insert() ]]
  vim.cmd [[ augroup END ]]
end

function M.enter_insert()
  local cursor = api.nvim_win_get_cursor(0)
  local bufnr = api.nvim_get_current_buf()

  -- proccess comment extmarked regions
  local exit = true
  local marks = api.nvim_buf_get_extmarks(bufnr, constants.OCTO_COMMENT_NS, 0, -1, {details = true})
  for _, mark in ipairs(marks) do
    local start_line = mark[2]
    local end_line = mark[4]["end_row"]
    if cursor[1] == 1 or -- title
      (start_line+1 < cursor[1] and end_line > cursor[1]) then
      exit = false
      break
    end
  end
  if exit then
    vim.cmd [[call feedkeys("\<esc>")]]
    print("Cannot make changes to non-editable regions")
  end

  -- format text
  local comment, start_line = util.get_comment_at_cursor(bufnr, cursor)
  if comment then
    local lines = vim.split(comment.body, "\n")
    api.nvim_buf_set_lines(bufnr, start_line, start_line + #lines, false, lines)
  end
end

function M.leave_insert()
  local cursor = api.nvim_win_get_cursor(0)
  local bufnr = api.nvim_get_current_buf()
  local comment, start_line = util.get_comment_at_cursor(bufnr, cursor)
  if comment then
    local lines = vim.split(comment.body, "\n")
    local alt_lines = {}
    for _, line in ipairs(lines) do
      table.insert(alt_lines, "⠀⠀⠀⠀".. line) -- "⠀" (U+2800)
    end
    api.nvim_buf_set_lines(bufnr, start_line, start_line + #alt_lines, false, alt_lines)
  end
end

function M.save_buffer()
  local bufnr = api.nvim_get_current_buf()

  -- for comment buffers, dispatch it to the right module
  if string.match(api.nvim_buf_get_name(bufnr), "octo://.+/.+/%d+/comment/.*") then
    require"octo.reviews".save_review_comment()
    return
  end

  local ft = api.nvim_buf_get_option(bufnr, "filetype")
  local repo, number = util.get_repo_number({"octo_issue", "octo_reviewthread"})
  if not repo then
    return
  end

  local issue_kind
  if string.match(api.nvim_buf_get_name(bufnr), "octo://.*/pull/.*") then
    issue_kind = "pull"
  elseif string.match(api.nvim_buf_get_name(bufnr), "octo://.*/issue/.*") then
    issue_kind = "issue"
  else
    return
  end

  -- collect comment metadata
  util.update_issue_metadata(bufnr)

  -- title & description
  if ft == "octo_issue" then
    local title_metadata = api.nvim_buf_get_var(bufnr, "title")
    local desc_metadata = api.nvim_buf_get_var(bufnr, "description")
    local id = api.nvim_buf_get_var(bufnr, "iid")
    if title_metadata.dirty or desc_metadata.dirty then
      -- trust but verify
      if string.find(title_metadata.body, "\n") then
        api.nvim_err_writeln("Title can't contains new lines")
        return
      elseif title_metadata.body == "" then
        api.nvim_err_writeln("Title can't be blank")
        return
      end

      local query
      if issue_kind == "issue" then
        query = graphql("update_issue_mutation", id, title_metadata.body, desc_metadata.body)
      elseif issue_kind == "pull" then
        query = graphql("update_pull_request_mutation", id, title_metadata.body, desc_metadata.body)
      end
      gh.run(
        {
          args = {"api", "graphql", "-f", format("query=%s", query)},
          cb = function(output)
            local resp = json.parse(output)
            local obj
            if issue_kind == "pull" then
              obj = resp.data.updatePullRequest.pullRequest
            elseif issue_kind == "issue" then
              obj = resp.data.updateIssue.issue
            end
            if title_metadata.body == obj.title then
              title_metadata.saved_body = obj.title
              title_metadata.dirty = false
              api.nvim_buf_set_var(bufnr, "title", title_metadata)
            end

            if desc_metadata.body == obj.body then
              desc_metadata.saved_body = obj.body
              desc_metadata.dirty = false
              api.nvim_buf_set_var(bufnr, "description", desc_metadata)
            end

            signs.render_signcolumn(bufnr)
            print("Saved!")
          end
        }
      )
    end
  end

  -- comments
  local comments = api.nvim_buf_get_var(bufnr, "comments")
  for _, metadata in ipairs(comments) do
    if metadata.body ~= metadata.saved_body then
      if metadata.id == -1 then
        if metadata.kind == "IssueComment" then
          -- create new comment
          local id = api.nvim_buf_get_var(bufnr, "iid")
          local add_query = graphql("add_issue_comment_mutation", id, metadata.body)
          gh.run(
            {
              args = {"api", "graphql", "-f", format("query=%s", add_query)},
              cb = function(output, stderr)
                if stderr and not util.is_blank(stderr) then
                  api.nvim_err_writeln(stderr)
                elseif output then
                  local resp = json.parse(output)
                  local resp_body = resp.data.addComment.commentEdge.node.body
                  local resp_id = resp.data.addComment.commentEdge.node.id
                  if vim.fn.trim(metadata.body) == vim.fn.trim(resp_body) then
                    for i, c in ipairs(comments) do
                      if tonumber(c.id) == -1 then
                        comments[i].id = resp_id
                        comments[i].saved_body = resp_body
                        comments[i].dirty = false
                        break
                      end
                    end
                    api.nvim_buf_set_var(bufnr, "comments", comments)
                    signs.render_signcolumn(bufnr)
                  end
                end
              end
            }
          )
        elseif metadata.kind == "PullRequestReviewComment" then
          -- create new thread reply
          local cid = metadata.first_comment_id
          if vim.bo.ft == "octo_issue" then
            cid = util.graph2rest(metadata.first_comment_id)
          end
          gh.run(
          {
            args = {
              "api",
              "-X",
              "POST",
              "-f",
              format("body=%s", metadata.body),
              format("/repos/%s/pulls/%d/comments/%s/replies", repo, number, cid)
            },
            cb = function(output, stderr)
              if stderr and not util.is_blank(stderr) then
                api.nvim_err_writeln(stderr)
              elseif output then
                local resp = json.parse(output)
                if vim.fn.trim(metadata.body) == vim.fn.trim(resp.body) then
                  for i, c in ipairs(comments) do
                    if tonumber(c.id) == -1 then
                      comments[i].id = resp.id
                      comments[i].saved_body = resp.body
                      comments[i].dirty = false
                      break
                    end
                  end
                  api.nvim_buf_set_var(bufnr, "comments", comments)
                  signs.render_signcolumn(bufnr)
                end
              end
            end
          }
        )
        elseif metadata.kind == "PullRequestReview" then
          -- Review top level comments cannot be created here
          return
        end
      else
        -- update comment/reply
        local update_query
        if metadata.kind == "IssueComment" then
          update_query = graphql("update_issue_comment_mutation", metadata.id, metadata.body)
        elseif metadata.kind == "PullRequestReviewComment" then
          update_query = graphql("update_pull_request_review_comment_mutation", metadata.id, metadata.body)
        elseif metadata.kind == "PullRequestReview" then
          update_query = graphql("update_pull_request_review_mutation", metadata.id, metadata.body)
        end
        gh.run(
          {
            args = {"api", "graphql", "-f", format("query=%s", update_query)},
            cb = function(output, stderr)
              if stderr and not util.is_blank(stderr) then
                api.nvim_err_writeln(stderr)
              elseif output then
                local resp = json.parse(output)
                local resp_body, resp_id
                if metadata.kind == "IssueComment" then
                  resp_body = resp.data.updateIssueComment.issueComment.body
                  resp_id = resp.data.updateIssueComment.issueComment.id
                elseif metadata.kind == "PullRequestReviewComment" then
                  resp_body = resp.data.updatePullRequestReviewComment.pullRequestReviewComment.body
                  resp_id = resp.data.updatePullRequestReviewComment.pullRequestReviewComment.id
                elseif metadata.kind == "PullRequestReview" then
                  resp_body = resp.data.updatePullRequestReview.pullRequestReview.body
                  resp_id = resp.data.updatePullRequestReview.pullRequestReview.id
                end
                if vim.fn.trim(metadata.body) == vim.fn.trim(resp_body) then
                  for i, c in ipairs(comments) do
                    if c.id == resp_id then
                      comments[i].saved_body = resp_body
                      comments[i].dirty = false
                      break
                    end
                  end
                  api.nvim_buf_set_var(bufnr, "comments", comments)
                  signs.render_signcolumn(bufnr)
                end
              end
            end
          }
        )
      end
    end
  end

  -- reset modified option
  api.nvim_buf_set_option(bufnr, "modified", false)
end

function M.apply_buffer_mappings(bufnr, kind)
  local mapping_opts = {silent = true, noremap = true}

  if kind == "issue" then
    api.nvim_buf_set_keymap(
      bufnr,
      "n",
      "<space>ic",
      [[<cmd>lua require'octo.commands'.change_issue_state('closed')<CR>]],
      mapping_opts
    )
    api.nvim_buf_set_keymap(
      bufnr,
      "n",
      "<space>io",
      [[<cmd>lua require'octo.commands'.change_issue_state('open')<CR>]],
      mapping_opts
    )

    local repo_ok, repo = pcall(api.nvim_buf_get_var, bufnr, "repo")
    if repo_ok then
      api.nvim_buf_set_keymap(
        bufnr,
        "n",
        "<space>il",
        format("<cmd>lua require'octo.menu'.issues('%s')<CR>", repo),
        mapping_opts
      )
    end
  elseif kind == "pull" then
    api.nvim_buf_set_keymap(
      bufnr,
      "n",
      "<space>po",
      [[<cmd>lua require'octo.commands'.checkout_pr()<CR>]],
      mapping_opts
    )
    api.nvim_buf_set_keymap(bufnr, "n", "<space>pc", [[<cmd>lua require'octo.menu'.commits()<CR>]], mapping_opts)
    api.nvim_buf_set_keymap(bufnr, "n", "<space>pf", [[<cmd>lua require'octo.menu'.files()<CR>]], mapping_opts)
    api.nvim_buf_set_keymap(
      bufnr,
      "n",
      "<space>pd",
      [[<cmd>lua require'octo.commands'.show_pr_diff()<CR>]],
      mapping_opts
    )
    api.nvim_buf_set_keymap(
      bufnr,
      "n",
      "<space>pm",
      [[<cmd>lua require'octo.commands'.merge_pr("commit")<CR>]],
      mapping_opts
    )
    api.nvim_buf_set_keymap(
      bufnr,
      "n",
      "<space>va",
      [[<cmd>lua require'octo.commands'.add_user('reviewer')<CR>]],
      mapping_opts
    )
    api.nvim_buf_set_keymap(
      bufnr,
      "n",
      "<space>vd",
      [[<cmd>lua require'octo.commands'.remove_user('reviewer')<CR>]],
      mapping_opts
    )
  end

  if kind == "issue" or kind == "pull" then
    api.nvim_buf_set_keymap(
      bufnr,
      "n",
      "<c-r>",
      [[<cmd>lua require'octo.commands'.reload()<CR>]],
      mapping_opts
    )
    api.nvim_buf_set_keymap(
      bufnr,
      "n",
      "<c-o>",
      [[<cmd>lua require'octo.util'.open_in_browser()<CR>]],
      mapping_opts
    )
    api.nvim_buf_set_keymap(
      bufnr,
      "n",
      "<space>la",
      [[<cmd>lua require'octo.commands'.add_label()<CR>]],
      mapping_opts
    )
    api.nvim_buf_set_keymap(
      bufnr,
      "n",
      "<space>ld",
      [[<cmd>lua require'octo.commands'.delete_label()<CR>]],
      mapping_opts
    )

    api.nvim_buf_set_keymap(
      bufnr,
      "n",
      "<space>aa",
      [[<cmd>lua require'octo.commands'.add_user('assignee')<CR>]],
      mapping_opts
    )
    api.nvim_buf_set_keymap(
      bufnr,
      "n",
      "<space>ad",
      [[<cmd>lua require'octo.commands'.remove_user('assignee')<CR>]],
      mapping_opts
    )
  end

  if kind == "issue" or kind == "pull" or kind == "reviewthread" then
    -- autocomplete
    api.nvim_buf_set_keymap(bufnr, "i", "@", "@<C-x><C-o>", mapping_opts)
    api.nvim_buf_set_keymap(bufnr, "i", "#", "#<C-x><C-o>", mapping_opts)

    -- navigation
    api.nvim_buf_set_keymap(
      bufnr,
      "n",
      "<space>gi",
      [[<cmd>lua require'octo.navigation'.go_to_issue()<CR>]],
      mapping_opts
    )

    -- comments
    api.nvim_buf_set_keymap(
      bufnr,
      "n",
      "<space>ca",
      [[<cmd>lua require'octo.commands'.add_comment()<CR>]],
      mapping_opts
    )

    api.nvim_buf_set_keymap(
      bufnr,
      "n",
      "<space>cd",
      [[<cmd>lua require'octo.commands'.delete_comment()<CR>]],
      mapping_opts
    )

    -- reactions
    api.nvim_buf_set_keymap(
      bufnr,
      "n",
      "<space>rp",
      [[<cmd>lua require'octo.commands'.reaction_action('add', 'hooray')<CR>]],
      mapping_opts
    )
    api.nvim_buf_set_keymap(
      bufnr,
      "n",
      "<space>rh",
      [[<cmd>lua require'octo.commands'.reaction_action('add', 'heart')<CR>]],
      mapping_opts
    )
    api.nvim_buf_set_keymap(
      bufnr,
      "n",
      "<space>re",
      [[<cmd>lua require'octo.commands'.reaction_action('add', 'eyes')<CR>]],
      mapping_opts
    )
    api.nvim_buf_set_keymap(
      bufnr,
      "n",
      "<space>r+",
      [[<cmd>lua require'octo.commands'.reaction_action('add', '+1')<CR>]],
      mapping_opts
    )
    api.nvim_buf_set_keymap(
      bufnr,
      "n",
      "<space>r-",
      [[<cmd>lua require'octo.commands'.reaction_action('add', '-1')<CR>]],
      mapping_opts
    )
    api.nvim_buf_set_keymap(
      bufnr,
      "n",
      "<space>rr",
      [[<cmd>lua require'octo.commands'.reaction_action('add', 'rocket')<CR>]],
      mapping_opts
    )
    api.nvim_buf_set_keymap(
      bufnr,
      "n",
      "<space>rl",
      [[<cmd>lua require'octo.commands'.reaction_action('add', 'laugh')<CR>]],
      mapping_opts
    )
    api.nvim_buf_set_keymap(
      bufnr,
      "n",
      "<space>rc",
      [[<cmd>lua require'octo.commands'.reaction_action('add', 'confused')<CR>]],
      mapping_opts
    )
  end
end

return M
