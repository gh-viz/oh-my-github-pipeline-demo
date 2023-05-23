require 'http'

class FetchStarredRepos 
  attr_reader :current_user, :login

  def initialize(login)
    @login = login
    @current_user = CurrentUser.where(login: login).first
    raise "current user not found" if @current_user.nil?
  end

  def query(cusor)
    if cusor 
      after = %Q|, after: "#{cusor}"|
    else
      after = ''
    end
    <<~GQL
      query {
        rateLimit {
          limit
          cost
          remaining
          resetAt
        }
        user(login: "#{login}") {
          repositories: starredRepositories(first: 100, orderBy: {field: STARRED_AT, direction: ASC} #{after}) {
            pageInfo {
              endCursor
              hasNextPage
            }
            edges {
              starredAt
              node {
                databaseId
                name
                owner {
                  login
                }
                isInOrganization
                licenseInfo {
                  name
                }
                isPrivate
                diskUsage
                primaryLanguage {
                  name
                }
                description
                isFork
                parent {
                  databaseId
                }
                createdAt
                updatedAt
                forkCount
                stargazerCount
                pushedAt
                repositoryTopics(first: 100){
                  edges {
                    node {
                      topic {
                        name
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    GQL
  end

  def run
    cusor = current_user.last_starred_repo_cursor
    remaining_count ||= 5000
    is_has_next_page = true
    loop do 
      # puts cusor 
      # puts remaining_count
      # puts is_has_next_page

      data = fetch_data(cusor)
      star_attrs = get_star_attrs(data)
      repo_attrs = get_repo_attrs(data)
      if star_attrs.blank?
        puts "All starred repos synced successed"
        break
      else
        StarredRepo.upsert_all(star_attrs)
        Repo.upsert_all(repo_attrs)
      end
      cusor = end_cusor(data)
      
      remaining_count = remaining(data)
      is_has_next_page = has_next_page(data)
      current_user.update(last_starred_repo_cursor: cusor) if cusor.present?
      if remaining_count == 1
        puts "You do not have enough remaining ratelimit, please try it after an hour."
        break
      end

      if not is_has_next_page
        puts "All starred repos synced successed"
        break
      end
    end
  end

  def fetch_data(cusor)
    q = query(cusor)
    puts "- Sync starred repos with cusor: #{cusor}"
    response = HTTP.post("https://api.github.com/graphql",
      headers: {
        "Authorization": "Bearer #{ENV['ACCESS_TOKEN']}",
        "Content-Type": "application/json"
      },
      json: { query: q }
    )
    response.parse
  end

  def remaining(data)
    data.dig("data", "rateLimit", "remaining")
  end

  def end_cusor(data)
    data.dig("data", "user", "repositories", "pageInfo", "endCursor")
  end

  def has_next_page(data)
    data.dig("data", "user", "repositories", "pageInfo", "hasNextPage")
  end

  def get_star_attrs(data)
    edges = data.dig("data", "user", "repositories", "edges")
    if edges.nil?
      puts data["errors"]
      raise "GitHub API issue, please try again later"
    end
    edges.map do |edge|
      hash = edge["node"]
      {
        repo_id: hash["databaseId"],
        starred_at: edge["starredAt"],
        user_id: current_user.id
      }
    end
  end

  def get_repo_attrs(data)
    edges = data.dig("data", "user", "repositories", "edges")
    if edges.nil?
      puts data["errors"]
      raise "GitHub API issue, please try again later"
    end
    edges.map do |edge|
      hash = edge["node"]
      {
        id: hash["databaseId"],
        name: hash["name"],
        owner: hash.dig("owner", "login"),
        license: hash.dig("licenseInfo", "name"),
        is_private: hash["isPrivate"],
        disk_usage: hash["diskUsage"],
        language: hash.dig("primaryLanguage", "name"),
        description: hash["description"],
        is_fork: hash["isFork"],
        parent_id: hash.dig("parent", "databaseId"),
        created_at: hash["createdAt"],
        updated_at: hash["updatedAt"],
        fork_count: hash["forkCount"],
        stargazer_count: hash["stargazerCount"],
        pushed_at: hash["pushedAt"],
        topics: hash["repositoryTopics"]["edges"].map{|edge| edge["node"]["topic"]["name"]},
        is_in_organization: hash["isInOrganization"]
      }
    end
  end
end
