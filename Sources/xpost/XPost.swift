import ArgumentParser

@main
struct XPost: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "xpost",
    abstract: "Cross-post to social networks",
    discussion: """
      xpost publishes the same update to Twitter/X, Mastodon, and Bluesky. Provide your \
      message as an argument, with --message, or on stdin. Posting is the default command; \
      see 'xpost help post' for its options.

      Examples:
        xpost --message "hello world" --image ./shot.png
        xpost "Ship it!" --target twitter --target mastodon
        echo "Release shipped" | xpost --target all
      """,
    subcommands: [Post.self, Twitter.self],
    defaultSubcommand: Post.self
  )
}
