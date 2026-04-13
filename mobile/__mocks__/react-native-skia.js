module.exports = {
  Skia: {
    Path: {
      Make: () => ({
        moveTo: jest.fn(),
        lineTo: jest.fn(),
        toSVGString: () => "M0,0 L10,10",
      }),
      MakeFromSVGString: (svg) =>
        svg
          ? { moveTo: jest.fn(), lineTo: jest.fn(), toSVGString: () => svg }
          : null,
    },
  },
  Canvas: "Canvas",
  Path: "Path",
  makeImageFromView: jest.fn(),
};
