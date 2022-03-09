SELECT
    `id`,
    `name`,
    `age`,
    `ctime`,
    `mtime`
FROM
    `user`
WHERE
    `id` > 0
    AND `age` > 0
ORDER BY
    `id`
LIMIT
    20 
OFFSET 
    0