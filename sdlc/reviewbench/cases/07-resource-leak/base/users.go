package users

import "database/sql"

func IDs(db *sql.DB) ([]int, error) {
	rows, err := db.Query("SELECT id FROM users")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var ids []int
	for rows.Next() {
		var id int
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}
