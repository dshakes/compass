function displayName(user) {
  const name = user.profile?.name ?? "anonymous";
  return name.trim();
}

module.exports = { displayName };
