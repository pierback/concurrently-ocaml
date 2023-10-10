const asf = async () => {
  await new Promise((resolve) => {
    return setTimeout(resolve, 10000);
  });

  console.log('finished lo ng long')
};
asf();